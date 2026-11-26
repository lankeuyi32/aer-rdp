use std::io;
use std::sync::{Arc, Mutex};

use ironrdp::connector::sspi::credssp::{
    CredSspServer, CredentialsProxy, EarlyUserAuthResult, NStatusCode, ServerError, ServerMode,
    ServerState, TsRequest,
};
use ironrdp::connector::sspi::generator::GeneratorState;
use ironrdp::connector::sspi::ntlm::NtlmConfig;
use ironrdp::connector::sspi::{self, AuthIdentity, Secret, Username, UsernameParts};
use ironrdp::connector::{ConnectorError, ConnectorErrorKind, ConnectorResult, ServerName, custom_err};
use ironrdp::core::{WriteBuf, other_err};
use ironrdp::pdu::PduHint;
use ironrdp::pdu::nego::SecurityProtocol;
use ironrdp_tokio::{Framed, FramedRead, FramedWrite};
use tracing::{debug, trace};

use crate::ServerMetricsInner;

#[derive(Clone, Copy, Debug)]
struct CredsspTsRequestHint;

const CREDSSP_TS_REQUEST_HINT: CredsspTsRequestHint = CredsspTsRequestHint;

impl PduHint for CredsspTsRequestHint {
    fn find_size(&self, bytes: &[u8]) -> ironrdp::core::DecodeResult<Option<(bool, usize)>> {
        match TsRequest::read_length(bytes) {
            Ok(length) => Ok(Some((true, length))),
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(None),
            Err(e) => Err(other_err!("CredsspTsRequestHint", source: e)),
        }
    }
}

struct MockCredentialsProxy {
    expected_username: String,
    expected_domain: String,
    expected_password: String,
}

impl CredentialsProxy for MockCredentialsProxy {
    type AuthenticationData = AuthIdentity;

    fn auth_data_by_user(&mut self, username: &Username) -> io::Result<Self::AuthenticationData> {
        if username.account_name() != self.expected_username {
            return Err(io::Error::other("invalid username"));
        }
        let domain_in_req = match username.parts() {
            UsernameParts::DownLevelLogonName(parts) => parts.netbios_domain(),
            UsernameParts::UserPrincipalName(_) => None,
        };
        if !self.expected_domain.is_empty() {
            let got_domain = domain_in_req.unwrap_or("");
            if !got_domain.eq_ignore_ascii_case(&self.expected_domain) {
                return Err(io::Error::other("invalid domain"));
            }
        }
        let domain_opt = if self.expected_domain.is_empty() {
            domain_in_req
        } else {
            Some(self.expected_domain.as_str())
        };
        let identity_user = Username::new(&self.expected_username, domain_opt)
            .map_err(|e| io::Error::other(format!("invalid username/domain: {e}")))?;
        Ok(AuthIdentity {
            username: identity_user,
            password: Secret::from(self.expected_password.clone()),
        })
    }

    fn auth_data(&mut self) -> Result<Vec<Self::AuthenticationData>, io::Error> {
        let domain_opt = (!self.expected_domain.is_empty()).then_some(self.expected_domain.as_str());
        let identity_user = Username::new(&self.expected_username, domain_opt)
            .map_err(|e| io::Error::other(format!("invalid username/domain: {e}")))?;
        Ok(vec![AuthIdentity {
            username: identity_user,
            password: Secret::from(self.expected_password.clone()),
        }])
    }
}

pub struct CredsspExpected<'a> {
    pub username: &'a str,
    pub domain: &'a str,
    pub password: &'a str,
}

pub async fn run_credssp<S>(
    framed: &mut Framed<S>,
    protocol: SecurityProtocol,
    client_computer_name: ServerName,
    public_key: Vec<u8>,
    expected: CredsspExpected<'_>,
    metrics: &Arc<Mutex<ServerMetricsInner>>,
) -> ConnectorResult<()>
where
    S: FramedRead + FramedWrite,
{
    let proxy = MockCredentialsProxy {
        expected_username: expected.username.to_owned(),
        expected_domain: expected.domain.to_owned(),
        expected_password: expected.password.to_owned(),
    };
    let server_mode = ServerMode::Ntlm(NtlmConfig::new(client_computer_name.into_inner()));
    let mut server = match CredSspServer::new(public_key, proxy, server_mode) {
        Ok(s) => s,
        Err(e) => {
            if let Ok(mut m) = metrics.lock() {
                m.auth_failures += 1;
                m.last_disconnect_reason = Some(format!("auth failed: [CredSSP] {e}"));
            }
            return Err(ConnectorError::new("CredSSP", ConnectorErrorKind::Credssp(e)));
        }
    };

    let mut buf = WriteBuf::new();

    let auth_result: ConnectorResult<()> = async {
        loop {
            let pdu = framed
                .read_by_hint(&CREDSSP_TS_REQUEST_HINT)
                .await
                .map_err(|e| custom_err!("read TsRequest", e))?;
            let req = TsRequest::from_buffer(&pdu).map_err(|e| custom_err!("TsRequest::from_buffer", e))?;
            trace!(?req, "CredSSP received TsRequest");

            let process_res = {
                let mut generator = server.process(req);
                let mut state = generator.start();
                loop {
                    match state {
                        GeneratorState::Suspended(_net_req) => {
                            state = generator.resume(Err(sspi::Error::new(
                                sspi::ErrorKind::InternalError,
                                "network client not supported in mock server",
                            )));
                        }
                        GeneratorState::Completed(res) => break res,
                    }
                }
            };

            match process_res {
                Ok(ServerState::ReplyNeeded(reply)) => {
                    buf.clear();
                    let len = usize::from(reply.buffer_len());
                    let slice = buf.unfilled_to(len);
                    reply
                        .encode_ts_request(slice)
                        .map_err(|e| custom_err!("encode TsRequest", e))?;
                    buf.advance(len);
                    framed
                        .write_all(buf.filled())
                        .await
                        .map_err(|e| custom_err!("write TsRequest", e))?;
                }
                Ok(ServerState::Finished(_identity)) => {
                    debug!("CredSSP authentication succeeded");
                    break Ok(());
                }
                Err(ServerError { ts_request, error }) => {
                    // Increment auth_failures before writing NStatusCode::LOGON_FAILURE or
                    // EarlyUserAuthResult::AccessDenied so client metric polls never race.
                    if let Ok(mut m) = metrics.lock() {
                        m.auth_failures += 1;
                        m.last_disconnect_reason =
                            Some(format!("auth failed: [CredSSP logon failure] {error}"));
                    }
                    let mut err_req = ts_request
                        .map(|boxed| *boxed)
                        .unwrap_or_default();
                    err_req.error_code = Some(NStatusCode::LOGON_FAILURE);
                    buf.clear();
                    let len = usize::from(err_req.buffer_len());
                    let slice = buf.unfilled_to(len);
                    if err_req.encode_ts_request(slice).is_ok() {
                        buf.advance(len);
                        let _ = framed.write_all(buf.filled()).await;
                    }
                    break Err(ConnectorError::new(
                        "CredSSP logon failure",
                        ConnectorErrorKind::Credssp(error),
                    ));
                }
            }
        }
    }
    .await;

    if protocol.intersects(SecurityProtocol::HYBRID_EX) {
        let early = if auth_result.is_ok() {
            EarlyUserAuthResult::Success
        } else {
            EarlyUserAuthResult::AccessDenied
        };
        let mut early_buf = Vec::with_capacity(early.buffer_len());
        early
            .to_buffer(&mut early_buf)
            .map_err(|e| custom_err!("EarlyUserAuthResult::to_buffer", e))?;
        framed
            .write_all(&early_buf)
            .await
            .map_err(|e| custom_err!("write EarlyUserAuthResult", e))?;
    }

    auth_result
}

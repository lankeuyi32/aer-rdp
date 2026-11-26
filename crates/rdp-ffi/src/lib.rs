pub mod api;
#[cfg(not(frb_expand))]
mod frb_generated;

#[cfg(frb_expand)]
#[allow(dead_code)]
mod frb_generated {
    #[derive(Clone)]
    pub struct StreamSink<T>(std::marker::PhantomData<T>);

    impl<T> StreamSink<T> {
        pub fn add(&self, _value: T) -> Result<(), ()> {
            Ok(())
        }
    }
}

#[cfg(not(frb_expand))]
unsafe extern "C" {
    fn frb_create_shutdown_callback();
    fn frb_dart_opaque_dart2rust_encode();
    fn frb_dart_opaque_drop_thread_box_persistent_handle();
    fn frb_dart_opaque_rust2dart_decode();
    fn frb_free_wire_sync_rust2dart_dco();
    fn frb_free_wire_sync_rust2dart_sse();
    fn frb_init_frb_dart_api_dl();
    fn frb_rust_vec_u8_free();
    fn frb_rust_vec_u8_new();
    fn frb_rust_vec_u8_resize();
}

/// Retains all 16 `flutter_rust_bridge` C ABI symbols against `ld64 -dead_strip` in static iOS builds.
#[cfg(not(frb_expand))]
#[unsafe(no_mangle)]
pub extern "C" fn dummy_method_to_enforce_bundling() -> usize {
    let ptrs: [usize; 16] = [
        frb_generated::frb_get_rust_content_hash as *const () as usize,
        frb_generated::frb_pde_ffi_dispatcher_primary as *const () as usize,
        frb_generated::frb_pde_ffi_dispatcher_sync as *const () as usize,
        frb_generated::frb_dart_fn_deliver_output as *const () as usize,
        frb_generated::frbgen_aer_rdp_rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFfiSessionHandle as *const () as usize,
        frb_generated::frbgen_aer_rdp_rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFfiSessionHandle as *const () as usize,
        frb_create_shutdown_callback as *const () as usize,
        frb_dart_opaque_dart2rust_encode as *const () as usize,
        frb_dart_opaque_drop_thread_box_persistent_handle as *const () as usize,
        frb_dart_opaque_rust2dart_decode as *const () as usize,
        frb_free_wire_sync_rust2dart_dco as *const () as usize,
        frb_free_wire_sync_rust2dart_sse as *const () as usize,
        frb_init_frb_dart_api_dl as *const () as usize,
        frb_rust_vec_u8_free as *const () as usize,
        frb_rust_vec_u8_new as *const () as usize,
        frb_rust_vec_u8_resize as *const () as usize,
    ];
    ptrs.into_iter().fold(0usize, |acc, ptr| {
        std::hint::black_box(acc.wrapping_add(std::hint::black_box(ptr)))
    })
}

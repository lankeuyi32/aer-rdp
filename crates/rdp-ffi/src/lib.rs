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

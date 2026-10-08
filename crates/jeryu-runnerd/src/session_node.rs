//! HTTPS/mTLS relay for a trusted control plane. Browser/user authentication and
//! durable enrollment belong to that control plane, not this root launcher.
mod config;
mod rpc;
mod serve;
mod streaming;
pub use config::SessionNodeConfig;
pub use rpc::{RpcOperation, RpcRequest};
pub use serve::serve;

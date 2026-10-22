//! Durable install state and the install request/response service.

pub mod service;

pub use service::{
    InstallRecord, InstallService, INSTALL_STATUS_DENIED, INSTALL_STATUS_FAILED,
    INSTALL_STATUS_INSTALLED, INSTALL_STATUS_NONE, INSTALL_STATUS_PENDING, INSTALL_STATUS_TIMEOUT,
    INSTALL_STATUS_UNKNOWN,
};

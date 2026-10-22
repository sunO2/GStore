//! Durable install state and the install orchestration service.

pub mod service;

pub use service::{
    InstallAttempt, InstallReconcileReport, InstallRecord, InstallService, INSTALL_STATUS_DENIED,
    INSTALL_STATUS_FAILED, INSTALL_STATUS_INSTALLED, INSTALL_STATUS_NONE, INSTALL_STATUS_PENDING,
    INSTALL_STATUS_TIMEOUT, INSTALL_STATUS_UNKNOWN,
};

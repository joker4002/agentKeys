use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

pub struct AppError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
    pub details: serde_json::Value,
}

impl AppError {
    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "UNAUTHORIZED",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn forbidden(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            code: "DENIED",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn not_found(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code: "NOT_FOUND",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn conflict(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            code: "ALREADY_CONSUMED",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn gone(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::GONE,
            code: "EXPIRED",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "INTERNAL_ERROR",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: "BAD_REQUEST",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn no_match(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code: "NO_MATCH",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn already_delivered(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            code: "ALREADY_DELIVERED",
            message: msg.into(),
            details: json!({}),
        }
    }

    pub fn rate_limit_exceeded(read_rate_limit: u32, retry_after_secs: u64) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: "rate_limit_exceeded",
            message: format!(
                "session exceeded {read_rate_limit} credential reads/minute; retry after {retry_after_secs} seconds"
            ),
            details: json!({
                "retry_after_secs": retry_after_secs,
                "read_rate_limit": read_rate_limit,
            }),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let mut body = json!({
            "error": self.code,
            "code": self.code,
            "message": self.message
        });
        if let (Some(obj), Some(details)) = (body.as_object_mut(), self.details.as_object()) {
            for (key, value) in details {
                obj.insert(key.clone(), value.clone());
            }
        }
        (self.status, Json(body)).into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;

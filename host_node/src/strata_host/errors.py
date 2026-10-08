from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


class DomainError(Exception):
    code: str = "DOMAIN_ERROR"
    status_code: int = 400

    def __init__(self, message: str, details: dict | None = None):
        self.message = message
        self.details = details or {}
        super().__init__(message)


class MacAlreadyActive(DomainError):
    code = "MAC_ALREADY_ACTIVE"
    status_code = 409


class NonceReplay(DomainError):
    code = "NONCE_REPLAY"
    status_code = 409


class SessionNotFound(DomainError):
    code = "SESSION_NOT_FOUND"
    status_code = 404


class SessionNotActive(DomainError):
    code = "SESSION_NOT_ACTIVE"
    status_code = 409


class HostFull(DomainError):
    code = "HOST_FULL"
    status_code = 409


class MissingQuery(DomainError):
    code = "MISSING_QUERY"
    status_code = 400


class MacNotFound(DomainError):
    code = "MAC_NOT_FOUND"
    status_code = 404


class MacUnresolved(DomainError):
    code = "MAC_UNRESOLVED"
    status_code = 422


class MacMismatch(DomainError):
    code = "MAC_MISMATCH"
    status_code = 422


class InvalidSignature(DomainError):
    code = "INVALID_SIGNATURE"
    status_code = 401


class HostWalletMismatch(DomainError):
    code = "HOST_WALLET_MISMATCH"
    status_code = 422


def _error_envelope(code: str, message: str, details: dict | None = None) -> dict:
    return {"error": {"code": code, "message": message, "details": details or {}}}


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(DomainError)
    async def handle_domain_error(_: Request, exc: DomainError):
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_envelope(exc.code, exc.message, exc.details),
        )

    @app.exception_handler(Exception)
    async def handle_internal_error(_: Request, exc: Exception):
        return JSONResponse(
            status_code=500,
            content=_error_envelope(
                "INTERNAL_ERROR",
                "An internal server error occurred.",
                {"type": type(exc).__name__},
            ),
        )


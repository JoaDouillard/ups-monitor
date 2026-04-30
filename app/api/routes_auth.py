"""
Authentification JWT — login / logout / vérification du token.
"""

from datetime import datetime, timezone, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status, Response, Request
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import JWTError, jwt
from passlib.context import CryptContext
from pydantic import BaseModel

from app.config import settings

router = APIRouter(prefix="/api/auth", tags=["auth"])

_pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
_oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login", auto_error=False)

ALGORITHM = "HS256"
COOKIE_NAME = "ups_token"


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int


def _verify_password(plain: str, hashed: str) -> bool:
    return _pwd_context.verify(plain, hashed)


def _hash_password(password: str) -> str:
    return _pwd_context.hash(password)


# Stocke le hash au démarrage pour ne pas hasher à chaque requête
_ADMIN_HASH = _hash_password(settings.admin_password)


def create_access_token(username: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.access_token_expire_minutes)
    return jwt.encode(
        {"sub": username, "exp": expire},
        settings.secret_key,
        algorithm=ALGORITHM,
    )


def get_current_user(
    request: Request,
    token_header: Annotated[str | None, Depends(_oauth2_scheme)] = None,
) -> str:
    """
    Vérifie le JWT depuis le cookie httpOnly OU le header Authorization.
    Lève 401 si invalide.
    """
    token = request.cookies.get(COOKIE_NAME) or token_header
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Non authentifié",
            headers={"WWW-Authenticate": "Bearer"},
        )
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[ALGORITHM])
        username: str = payload.get("sub", "")
        if not username:
            raise JWTError("no sub")
        return username
    except JWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token invalide ou expiré",
            headers={"WWW-Authenticate": "Bearer"},
        )


CurrentUser = Annotated[str, Depends(get_current_user)]


@router.post("/login", response_model=TokenResponse)
async def login(
    response: Response,
    form_data: Annotated[OAuth2PasswordRequestForm, Depends()],
):
    """Authentifie l'utilisateur et renvoie un JWT (+ cookie httpOnly)."""
    if form_data.username != settings.admin_username or not _verify_password(
        form_data.password, _ADMIN_HASH
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Identifiants incorrects",
        )

    token = create_access_token(form_data.username)
    expires = settings.access_token_expire_minutes * 60

    response.set_cookie(
        key=COOKIE_NAME,
        value=token,
        httponly=True,
        max_age=expires,
        samesite="lax",
        secure=False,  # Passer à True en HTTPS
    )

    return TokenResponse(access_token=token, expires_in=expires)


@router.post("/logout")
async def logout(response: Response):
    """Supprime le cookie de session."""
    response.delete_cookie(COOKIE_NAME)
    return {"message": "Déconnecté"}


@router.get("/me")
async def me(current_user: CurrentUser):
    """Renvoie le nom d'utilisateur connecté."""
    return {"username": current_user}

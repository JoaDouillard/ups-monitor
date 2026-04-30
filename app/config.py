from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import Optional


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # Onduleur
    ups_host: str = "192.168.1.100"
    ups_port: int = 161

    # SNMPv3
    snmp_user: str = "upsnms"
    snmp_auth_key: str = ""
    snmp_priv_key: str = ""
    snmp_auth_protocol: str = "SHA"
    snmp_priv_protocol: str = "AES"
    snmp_timeout: int = 5
    snmp_retries: int = 2

    # Polling
    poll_interval: int = 30

    # Application
    secret_key: str = "CHANGEZ_MOI"
    admin_username: str = "admin"
    admin_password: str = "admin"
    access_token_expire_minutes: int = 480

    # Base de données
    database_url: str = "sqlite+aiosqlite:///./ups_monitor.db"
    history_retention_days: int = 30

    # Email (optionnel)
    smtp_host: Optional[str] = None
    smtp_port: int = 587
    smtp_user: Optional[str] = None
    smtp_password: Optional[str] = None
    smtp_from: str = "ups-monitor@local"
    alert_email_to: Optional[str] = None
    smtp_tls: bool = True

    # XenServer
    xenserver_host: Optional[str] = None
    xenserver_user: str = "root"
    xenserver_password: Optional[str] = None
    shutdown_delay_seconds: int = 60


settings = Settings()

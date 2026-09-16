# backend/app/models/__init__.py

from app.core.database import Base
from .user import User
from .vehicle import Vehicle
from .ride import Trip
from .review import Review
from .payment import PaymentMethod, PaymentTransaction
from .refund import RefundRequest
from .admin_user import AdminUser
from .waypoint import TripWaypoint
from .credential import UserCredential, CredentialType, CredentialStatus
from .rating import VehicleRating, RatingTag
from .reputation import ReputationScore, ReputationHistory, UserBan
from .delegation import OperatorDelegation
from .agent_decision import AgentDecisionRecord
from .refresh_token import RefreshToken

# 確保所有模型都被導入，這樣 Base.metadata 才能找到它們
__all__ = [
    "Base",
    "User",
    "Vehicle",
    "Trip",
    "Review",
    "PaymentMethod",
    "PaymentTransaction",
    "RefundRequest",
    "AdminUser",
    "TripWaypoint",
    "UserCredential",
    "CredentialType",
    "CredentialStatus",
    # 評價與信譽系統
    "VehicleRating",
    "RatingTag",
    "ReputationScore",
    "ReputationHistory",
    "UserBan",
    "OperatorDelegation",
    "AgentDecisionRecord",
    "RefreshToken",
]

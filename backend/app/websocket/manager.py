"""
WebSocket 連接管理器
負責管理所有 WebSocket 連接、房間和用戶映射
"""
import socketio
from typing import Dict, Set, Optional
from fastapi import HTTPException
from app.core.security import TokenError, decode_token
import logging

logger = logging.getLogger(__name__)


class ConnectionManager:
    """管理 WebSocket 連接和房間"""

    def __init__(self, sio: socketio.AsyncServer):
        self.sio = sio
        # 儲存用戶 ID 到 Socket ID 的映射
        self.user_to_socket: Dict[int, str] = {}
        # 儲存 Socket ID 到 用戶 ID 的映射
        self.socket_to_user: Dict[str, int] = {}
        # 儲存房間中的用戶
        self.rooms: Dict[str, Set[int]] = {}

    def verify_token(self, token: str) -> Optional[int]:
        """
        驗證 JWT Token 並返回用戶 ID

        Args:
            token: JWT Token

        Returns:
            用戶 ID，如果 token 無效則返回 None
        """
        try:
            # 與 REST 同一套規則：只收 type=access
            return int(decode_token(token, "access"))
        except (TokenError, ValueError) as e:
            logger.error(f"Token 驗證失敗: {e}")
            return None

    async def connect_user(self, sid: str, user_id: int):
        """
        註冊用戶連接

        Args:
            sid: Socket ID
            user_id: 用戶 ID
        """
        # 如果用戶已有連接，先斷開舊連接
        if user_id in self.user_to_socket:
            old_sid = self.user_to_socket[user_id]
            logger.info(f"用戶 {user_id} 有舊連接 {old_sid}，將被新連接取代")

        self.user_to_socket[user_id] = sid
        self.socket_to_user[sid] = user_id
        logger.info(f"用戶 {user_id} 已連接，Socket ID: {sid}")

    async def disconnect_user(self, sid: str):
        """
        註銷用戶連接

        Args:
            sid: Socket ID
        """
        user_id = self.socket_to_user.get(sid)
        if user_id:
            # 從所有房間中移除
            for room_name in list(self.rooms.keys()):
                if user_id in self.rooms[room_name]:
                    self.rooms[room_name].remove(user_id)
                    if not self.rooms[room_name]:
                        del self.rooms[room_name]

            # 清理映射
            del self.socket_to_user[sid]
            if user_id in self.user_to_socket and self.user_to_socket[user_id] == sid:
                del self.user_to_socket[user_id]

            logger.info(f"用戶 {user_id} 已斷開連接，Socket ID: {sid}")

    async def join_room(self, sid: str, room_name: str) -> bool:
        """
        用戶加入房間

        Args:
            sid: Socket ID
            room_name: 房間名稱

        Returns:
            是否成功加入
        """
        user_id = self.socket_to_user.get(sid)
        if not user_id:
            logger.error(f"Socket {sid} 沒有對應的用戶")
            return False

        # 加入 Socket.IO 房間
        await self.sio.enter_room(sid, room_name)

        # 記錄到房間映射
        if room_name not in self.rooms:
            self.rooms[room_name] = set()
        self.rooms[room_name].add(user_id)

        logger.info(f"用戶 {user_id} 加入房間 {room_name}")
        return True

    async def leave_room(self, sid: str, room_name: str):
        """
        用戶離開房間

        Args:
            sid: Socket ID
            room_name: 房間名稱
        """
        user_id = self.socket_to_user.get(sid)
        if user_id and room_name in self.rooms:
            self.rooms[room_name].discard(user_id)
            if not self.rooms[room_name]:
                del self.rooms[room_name]

        # 離開 Socket.IO 房間
        await self.sio.leave_room(sid, room_name)
        logger.info(f"用戶 {user_id} 離開房間 {room_name}")

    async def emit_to_room(self, room_name: str, event: str, data: dict):
        """
        向房間內所有用戶發送事件

        Args:
            room_name: 房間名稱
            event: 事件名稱
            data: 事件數據
        """
        await self.sio.emit(event, data, room=room_name)
        logger.info(f"向房間 {room_name} 發送事件 {event}")

    async def emit_to_user(self, user_id: int, event: str, data: dict):
        """
        向特定用戶發送事件

        Args:
            user_id: 用戶 ID
            event: 事件名稱
            data: 事件數據
        """
        sid = self.user_to_socket.get(user_id)
        if sid:
            await self.sio.emit(event, data, room=sid)
            logger.info(f"向用戶 {user_id} 發送事件 {event}")
        else:
            logger.warning(f"用戶 {user_id} 未連接，無法發送事件 {event}")

    def get_room_users(self, room_name: str) -> Set[int]:
        """
        獲取房間內的所有用戶 ID

        Args:
            room_name: 房間名稱

        Returns:
            用戶 ID 集合
        """
        return self.rooms.get(room_name, set()).copy()

    def is_user_online(self, user_id: int) -> bool:
        """
        檢查用戶是否在線

        Args:
            user_id: 用戶 ID

        Returns:
            是否在線
        """
        return user_id in self.user_to_socket

    def get_user_id(self, sid: str) -> Optional[int]:
        """
        根據 Socket ID 獲取用戶 ID

        Args:
            sid: Socket ID

        Returns:
            用戶 ID，如果不存在則返回 None
        """
        return self.socket_to_user.get(sid)

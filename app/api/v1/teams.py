"""Team router — thin HTTP layer; logic lives in TeamService.

AUTHZ:
- GET list/detail: any authenticated active user (supervisors see their team
  on mobile; admins manage on web). create/update/delete/membership are
  ADMIN-only per the project's role matrix.
"""
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import CurrentUser, get_current_admin, get_db
from app.models.user import User
from app.schemas.team import (
    AddMemberRequest,
    TeamCreate,
    TeamDetailOut,
    TeamOut,
    TeamUpdate,
)
from app.services.team_service import TeamService

router = APIRouter(prefix="/teams", tags=["teams"])


def _client_ip(request: Request) -> str | None:
    return request.headers.get("x-real-ip") or (
        request.client.host if request.client else None
    )


@router.get("", response_model=list[TeamOut])
async def list_teams(
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[TeamOut]:
    return await TeamService(db).list_teams()


@router.get("/{team_id}", response_model=TeamDetailOut)
async def get_team(
    team_id: int,
    _user: CurrentUser,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TeamDetailOut:
    return await TeamService(db).get_detail(team_id)


@router.post("", response_model=TeamDetailOut, status_code=201)
async def create_team(
    body: TeamCreate,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TeamDetailOut:
    return await TeamService(db).create(body, actor=admin, ip=_client_ip(request))


@router.put("/{team_id}", response_model=TeamDetailOut)
async def update_team(
    team_id: int,
    body: TeamUpdate,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TeamDetailOut:
    return await TeamService(db).update(
        team_id, body, actor=admin, ip=_client_ip(request)
    )


@router.delete("/{team_id}", status_code=204, response_class=Response)
async def delete_team(
    team_id: int,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> Response:
    await TeamService(db).soft_delete(team_id, actor=admin, ip=_client_ip(request))
    return Response(status_code=204)


@router.post("/{team_id}/members", response_model=TeamDetailOut)
async def add_member(
    team_id: int,
    body: AddMemberRequest,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TeamDetailOut:
    return await TeamService(db).add_member(
        team_id, body, actor=admin, ip=_client_ip(request)
    )


@router.delete("/{team_id}/members/{user_id}", response_model=TeamDetailOut)
async def remove_member(
    team_id: int,
    user_id: int,
    request: Request,
    admin: Annotated[User, Depends(get_current_admin)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TeamDetailOut:
    return await TeamService(db).remove_member(
        team_id, user_id, actor=admin, ip=_client_ip(request)
    )

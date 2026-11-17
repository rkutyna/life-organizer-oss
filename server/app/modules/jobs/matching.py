"""When two job records are the same: company names, posting titles and people.

A company is the same company when its name matches ignoring case and spacing ("Acme Corp" and
"acme  corp"). A posting's title matches when it is equal after that fold with punctuation also
read as a space, so "Engineer, Platform" and "Engineer - Platform" match. Only these exact folds
match: there is no fuzzy match, so two different postings are never joined by a guess.
"""

import re

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.modules.jobs.models import Application, Company, Contact

_PUNCTUATION = re.compile(r"[^\w\s]")


def fold_name(text: str | None) -> str:
    return " ".join((text or "").split()).casefold()


def fold_title(text: str | None) -> str:
    return fold_name(_PUNCTUATION.sub(" ", text or ""))


def company_named(session: Session, name: str, *, exclude_id: int | None = None) -> Company | None:
    """The live company whose name matches `name` ignoring case and spacing."""
    wanted = fold_name(name)
    if not wanted:
        return None
    for company in session.scalars(select(Company).order_by(Company.id)):
        if company.id != exclude_id and fold_name(company.name) == wanted:
            return company
    return None


def same_posting(
    session: Session, company_id: int, title: str, statuses: list[str] | None = None
) -> list[Application]:
    """Live rows at this company whose title matches `title`, oldest first, optionally only
    those with one of `statuses`."""
    stmt = select(Application).where(Application.company_id == company_id)
    if statuses is not None:
        stmt = stmt.where(Application.status.in_(statuses))
    wanted = fold_title(title)
    return [
        row
        for row in session.scalars(stmt.order_by(Application.id))
        if fold_title(row.title) == wanted
    ]


def same_contact(session: Session, name: str, company_id: int | None) -> list[Contact]:
    """Live contacts with this name (ignoring case and spacing) at this company (or at none)."""
    stmt = select(Contact).where(
        Contact.company_id.is_(None) if company_id is None else Contact.company_id == company_id
    )
    wanted = fold_name(name)
    return [
        row for row in session.scalars(stmt.order_by(Contact.id)) if fold_name(row.name) == wanted
    ]

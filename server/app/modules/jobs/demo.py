"""A fictional job search for the demo and README screenshots.

    from app.modules.jobs import demo
    demo.seed(session)

Companies, applications across the statuses (with their history), open and dropped leads, a few
contacts with next actions due, an interview and an event this week, and two weekly goals. Every
name is made up. Everything is written through `app.audit` as author `system`, in one batch.
Dates are relative to today, so the demo always looks current. Seeding twice adds nothing: it
returns early if any company exists.
"""

import datetime as dt

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit
from app.modules.jobs import service
from app.modules.jobs.models import Company, Contact, Interview, JobEvent, WeeklyGoal
from app.timeutil import today_local

AUTHOR = "system"

COMPANIES = [
    # name, target, tags, notes
    ("Acme Corp", True, ["remote", "hardware"], "Makes everything. Strong mentoring culture."),
    ("Example Labs", True, ["research"], "Small applied research team."),
    ("Globex", False, ["fintech"], ""),
    ("Initech", False, ["enterprise"], "Several openings on the platform team."),
    ("Umbrella Health", True, ["health", "hybrid"], ""),
    ("Northwind Traders", False, ["retail"], ""),
    ("Contoso", False, ["cloud", "remote"], "Met their recruiter at the fall fair."),
    ("Stark Industrial", False, ["hardware"], ""),
]

# company, title, days ago applied, history after applied [(status, days after applied)], extras
APPLICATIONS = [
    (
        "Acme Corp",
        "Software Engineer, Platform",
        24,
        [("screen", 6), ("interview", 12)],
        {"source": "Company site", "location": "Remote", "tags": ["referral"]},
    ),
    (
        "Example Labs",
        "Research Engineer",
        20,
        [("screen", 8)],
        {"source": "Job board", "location": "Springfield"},
    ),
    ("Globex", "Backend Developer", 30, [("rejected", 14)], {"source": "Job board"}),
    ("Initech", "Platform Engineer", 18, [], {"source": "Recruiter", "location": "Hybrid"}),
    ("Initech", "Site Reliability Engineer", 35, [("screen", 7), ("ghosted", 25)], {}),
    (
        "Umbrella Health",
        "Data Engineer",
        12,
        [("screen", 5), ("interview", 9), ("offer", 11)],
        {"location": "Hybrid", "tags": ["dream job"]},
    ),
    ("Northwind Traders", "Full-Stack Developer", 9, [], {"source": "Career fair"}),
    ("Contoso", "Cloud Support Engineer", 40, [("withdrawn", 10)], {}),
    (
        "Stark Industrial",
        "Embedded Software Engineer",
        5,
        [],
        {"next_action": "Check the portal", "next_action_due_in": 2},
    ),
    ("Globex", "Data Analyst", 0, [], {"source": "Referral", "tags": ["referral"]}),
]

LEADS = [
    ("Example Labs", "Machine Learning Engineer", 2, {"source": "Newsletter"}),
    ("Contoso", "Solutions Engineer", 1, {"posting_url": "https://example.com/jobs/1234"}),
    ("Acme Corp", "Developer Advocate", 4, {}),
]

DROPPED = [("Northwind Traders", "Store Systems Analyst", 8, "Needs relocation")]

# name, company, role, contacted days ago, replied days ago, next action, due in days
CONTACTS = [
    ("Jane Doe", "Acme Corp", "Engineering Manager", 20, 18, "Send thank-you note", 0),
    ("John Roe", "Example Labs", "Recruiter", 15, None, "Follow up on the screen", 1),
    ("Alex Example", "Contoso", "Recruiter", 30, 28, "Ask about the solutions team", 3),
    ("Sam Sample", "Umbrella Health", "Data Lead", 10, 9, "", None),
    ("Pat Placeholder", None, "Career coach", 0, None, "Share the updated resume", -1),
]


def seed(session: Session) -> None:
    if session.scalars(select(Company.id)).first() is not None:
        return
    today = today_local()
    monday = today - dt.timedelta(days=today.weekday())
    with audit.transaction(session):
        companies: dict[str, Company] = {}
        for name, target, tags, notes in COMPANIES:
            company, _ = service.create_company(
                session, {"name": name, "target": target, "tags": tags, "notes": notes}, AUTHOR
            )
            companies[name] = company

        applications = {}
        for company, title, ago, history, extra in APPLICATIONS:
            extra = dict(extra)
            due_in = extra.pop("next_action_due_in", None)
            applied = today - dt.timedelta(days=ago)
            fields = {
                "company_id": companies[company].id,
                "title": title,
                "date_applied": applied,
                **extra,
            }
            if due_in is not None:
                fields["next_action_due"] = today + dt.timedelta(days=due_in)
            application = service.create_application(session, fields, AUTHOR).application
            for status, after in history:
                service.add_status(
                    session, application, status, AUTHOR, on_date=applied + dt.timedelta(after)
                )
            applications[title] = application

        for company, title, ago, extra in LEADS:
            service.create_lead(
                session,
                {"company_id": companies[company].id, "title": title, **extra},
                AUTHOR,
                found_on=today - dt.timedelta(days=ago),
            )
        for company, title, ago, reason in DROPPED:
            lead = service.create_lead(
                session,
                {"company_id": companies[company].id, "title": title},
                AUTHOR,
                found_on=today - dt.timedelta(days=ago),
            )
            service.drop_lead(session, lead, reason, AUTHOR)

        for name, company, role, contacted, replied, action, due in CONTACTS:
            audit.create(
                session,
                Contact(
                    name=name,
                    company_id=companies[company].id if company else None,
                    role=role,
                    contacted_on=today - dt.timedelta(days=contacted),
                    replied_on=None if replied is None else today - dt.timedelta(days=replied),
                    next_action=action,
                    next_action_due=None if due is None else today + dt.timedelta(days=due),
                    tags=[],
                ),
                AUTHOR,
            )

        # An interview and an event this week (at least a day apart from the edges).
        interview_day = max(today, monday + dt.timedelta(days=2))
        audit.create(
            session,
            Interview(
                application_id=applications["Software Engineer, Platform"].id,
                stage="Onsite",
                on_date=interview_day,
                start_time=dt.time(14, 0),
                duration_minutes=90,
                location="Video call",
                interviewer="Jane Doe",
            ),
            AUTHOR,
        )
        audit.create(
            session,
            Interview(
                application_id=applications["Research Engineer"].id,
                stage="Technical",
                on_date=interview_day + dt.timedelta(days=1),
                start_time=dt.time(10, 30),
                duration_minutes=60,
            ),
            AUTHOR,
        )
        audit.create(
            session,
            JobEvent(
                name="City Tech Career Fair",
                kind="fair",
                on_date=monday + dt.timedelta(days=3),
                start_time=dt.time(17, 0),
                end_time=dt.time(19, 30),
                location="Convention Center, Hall B",
                tags=[],
            ),
            AUTHOR,
        )
        audit.create(session, WeeklyGoal(metric="applications", target=5), AUTHOR)
        audit.create(session, WeeklyGoal(metric="outreach", target=3), AUTHOR)

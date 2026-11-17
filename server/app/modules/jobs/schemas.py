"""Request and response models for /api/jobs.

Names are prefixed `Job`/`Jobs` where a bare name could collide with another module's schema in
the shared OpenAPI document. Update models list every editable field as optional: send only the
fields to change (`exclude_unset`); a nullable field sent as null is cleared.
"""

import datetime as dt
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.modules.jobs.goals import METRICS

Metric = Literal["applications", "outreach", "leads", "interviews", "events"]
assert set(METRICS) == set(Metric.__args__)  # type: ignore[attr-defined]

Name = Field(min_length=1, max_length=200)
Tags = Field(default_factory=list, description="Free-form labels, e.g. remote or referral")


class _Out(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class _Record(_Out):
    created_at: dt.datetime
    created_by: str
    updated_at: dt.datetime


# --------------------------------------------------------------------------- statuses


class JobStatusOut(BaseModel):
    key: str
    label: str
    kind: Literal["lead", "dropped", "active", "closed"]
    position: int
    reserved: bool = Field(description="lead, applied and dropped: renamable, never removed")


class JobStatusCreate(BaseModel):
    label: str = Field(min_length=1, max_length=100)
    kind: Literal["active", "closed"]
    key: str | None = Field(
        default=None, description="Lowercase id; made from the label when left out"
    )


class JobStatusUpdate(BaseModel):
    label: str | None = Field(default=None, min_length=1, max_length=100)
    kind: Literal["active", "closed"] | None = None


class JobStatusOrder(BaseModel):
    keys: list[str]


# --------------------------------------------------------------------------- companies


class CompanyBase(BaseModel):
    website: str = Field(default="", max_length=500)
    target: bool = False
    notes: str = ""
    tags: list[str] = Tags


class CompanyCreate(CompanyBase):
    name: str = Name
    reuse_existing: bool = Field(
        default=False,
        description="When the name is taken (ignoring case and spacing), return that company "
        "instead of refusing",
    )


class CompanyUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    website: str | None = Field(default=None, max_length=500)
    target: bool | None = None
    notes: str | None = None
    tags: list[str] | None = None


class CompanyOut(_Record):
    id: int
    name: str
    website: str
    target: bool
    notes: str
    tags: list[str]


class CompanyRowOut(CompanyOut):
    applications: int = Field(description="Submitted applications (leads not counted)")
    leads: int = Field(description="Open leads")
    contacts: int


class CompanyCreatedOut(CompanyOut):
    created: bool = Field(description="False when reuse_existing returned an existing company")


# --------------------------------------------------------------------------- applications


class ApplicationFields(BaseModel):
    location: str = Field(default="", max_length=200)
    posting_url: str = Field(default="", max_length=2000)
    source: str = Field(default="", max_length=200, description="Where the posting was found")
    next_action: str = ""
    next_action_due: dt.date | None = None
    notes: str = ""
    tags: list[str] = Tags


class CompanyRef(BaseModel):
    company_id: int | None = Field(default=None, description="An existing company")
    company: str | None = Field(
        default=None,
        min_length=1,
        max_length=200,
        description="A company name, matched ignoring case and spacing and created if new; "
        "used when company_id is left out",
    )


class ApplicationCreate(ApplicationFields, CompanyRef):
    title: str = Field(min_length=1, max_length=300)
    status: str | None = Field(default=None, description="An active or closed status; applied")
    date_applied: dt.date | None = Field(default=None, description="Defaults to today")


class ApplicationUpdate(BaseModel):
    company_id: int | None = None
    title: str | None = Field(default=None, min_length=1, max_length=300)
    date_applied: dt.date | None = None
    location: str | None = Field(default=None, max_length=200)
    posting_url: str | None = Field(default=None, max_length=2000)
    source: str | None = Field(default=None, max_length=200)
    next_action: str | None = None
    next_action_due: dt.date | None = None
    notes: str | None = None
    tags: list[str] | None = None


class ApplicationOut(_Record):
    id: int
    company_id: int
    company: str = Field(description="The company's name")
    title: str
    status: str
    date_applied: dt.date | None
    location: str
    posting_url: str
    source: str
    next_action: str
    next_action_due: dt.date | None
    notes: str
    tags: list[str]
    extra: dict[str, str]
    reached: str | None = Field(
        description="The furthest active stage in its history (None for a lead)"
    )


class ApplicationCreatedOut(ApplicationOut):
    company_created: bool = False
    promoted_from_lead: bool = Field(
        default=False, description="An open lead with the same title became this application"
    )
    lead_candidates: list[int] = Field(
        default_factory=list,
        description="Several open leads matched, so none was chosen; their ids",
    )


class LeadCreate(ApplicationFields, CompanyRef):
    title: str = Field(min_length=1, max_length=300)
    found_on: dt.date | None = Field(default=None, description="Defaults to today")
    force: bool = Field(
        default=False, description="Log it even when the posting is already tracked (a repost)"
    )


class JobStatusChange(BaseModel):
    status: str
    on_date: dt.date | None = Field(default=None, description="Defaults to today")
    note: str = ""


class JobApplyIn(BaseModel):
    on_date: dt.date | None = Field(default=None, description="Defaults to today")
    status: str | None = Field(default=None, description="A status past applied, if any")


class JobDropIn(BaseModel):
    reason: str = Field(min_length=1, max_length=1000)


class StatusEventOut(_Record):
    id: int
    application_id: int
    status: str
    on_date: dt.date
    note: str


class StatusEventUpdate(BaseModel):
    status: str | None = None
    on_date: dt.date | None = None
    note: str | None = None


# --------------------------------------------------------------------------- contacts


class ContactCreate(CompanyRef):
    name: str = Name
    role: str = Field(default="", max_length=200)
    email: str = Field(default="", max_length=320)
    profile_url: str = Field(default="", max_length=500)
    contacted_on: dt.date | None = None
    replied_on: dt.date | None = None
    next_action: str = ""
    next_action_due: dt.date | None = None
    notes: str = ""
    tags: list[str] = Tags


class ContactUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    company_id: int | None = None
    role: str | None = Field(default=None, max_length=200)
    email: str | None = Field(default=None, max_length=320)
    profile_url: str | None = Field(default=None, max_length=500)
    contacted_on: dt.date | None = None
    replied_on: dt.date | None = None
    next_action: str | None = None
    next_action_due: dt.date | None = None
    notes: str | None = None
    tags: list[str] | None = None


class ContactOut(_Record):
    id: int
    name: str
    company_id: int | None
    company: str | None
    role: str
    email: str
    profile_url: str
    contacted_on: dt.date | None
    replied_on: dt.date | None
    next_action: str
    next_action_due: dt.date | None
    notes: str
    tags: list[str]


class ContactCreatedOut(ContactOut):
    company_created: bool = False


# --------------------------------------------------------------------------- interviews


class InterviewCreate(BaseModel):
    application_id: int
    stage: str = Field(default="", max_length=100)
    on_date: dt.date | None = None
    start_time: dt.time | None = Field(default=None, description="Local wall-clock time")
    duration_minutes: int | None = Field(default=None, ge=5, le=24 * 60)
    location: str = Field(default="", max_length=500)
    interviewer: str = Field(default="", max_length=200)
    notes: str = ""


class InterviewUpdate(BaseModel):
    stage: str | None = Field(default=None, max_length=100)
    on_date: dt.date | None = None
    start_time: dt.time | None = None
    duration_minutes: int | None = Field(default=None, ge=5, le=24 * 60)
    location: str | None = Field(default=None, max_length=500)
    interviewer: str | None = Field(default=None, max_length=200)
    notes: str | None = None


class InterviewOut(_Record):
    id: int
    application_id: int
    company_id: int
    company: str
    application_title: str
    stage: str
    on_date: dt.date | None
    start_time: dt.time | None
    duration_minutes: int | None
    location: str
    interviewer: str
    notes: str


# --------------------------------------------------------------------------- events


class JobEventCreate(BaseModel):
    name: str = Field(min_length=1, max_length=300)
    kind: str = Field(default="", max_length=50, description="fair, networking, info session")
    on_date: dt.date
    start_time: dt.time | None = None
    end_time: dt.time | None = None
    location: str = Field(default="", max_length=500)
    url: str = Field(default="", max_length=2000)
    attended: bool | None = None
    notes: str = ""
    tags: list[str] = Tags


class JobEventUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=300)
    kind: str | None = Field(default=None, max_length=50)
    on_date: dt.date | None = None
    start_time: dt.time | None = None
    end_time: dt.time | None = None
    location: str | None = Field(default=None, max_length=500)
    url: str | None = Field(default=None, max_length=2000)
    attended: bool | None = None
    notes: str | None = None
    tags: list[str] | None = None


class JobEventOut(_Record):
    id: int
    name: str
    kind: str
    on_date: dt.date
    start_time: dt.time | None
    end_time: dt.time | None
    location: str
    url: str
    attended: bool | None
    notes: str
    tags: list[str]


# --------------------------------------------------------------------------- goals, pipeline


class WeeklyGoalCreate(BaseModel):
    metric: Metric
    target: int = Field(ge=0, le=1000)


class WeeklyGoalUpdate(BaseModel):
    target: int = Field(ge=0, le=1000)


class WeeklyGoalOut(_Record):
    id: int
    metric: Metric
    target: int


class GoalProgressOut(BaseModel):
    id: int
    metric: Metric
    label: str
    target: int
    actual: int


class WeekProgressOut(BaseModel):
    week_start: dt.date
    week_end: dt.date
    goals: list[GoalProgressOut]


class PipelineStatusCount(BaseModel):
    status: str
    label: str
    kind: str
    count: int


class PipelineStageCount(BaseModel):
    status: str
    label: str
    count: int


class PipelineLeads(BaseModel):
    open: int
    dropped: int


class PipelineInterviews(BaseModel):
    applications: int = Field(description="Applications with at least one interview")
    records: int


class PipelineOut(BaseModel):
    total: int = Field(description="Submitted applications (leads not counted)")
    by_status: list[PipelineStatusCount] = Field(description="Current status only")
    reached: list[PipelineStageCount] = Field(
        description="Per active stage, applications whose history got that far or past"
    )
    leads: PipelineLeads
    interviews: PipelineInterviews


class JobTagsOut(BaseModel):
    tags: list[str]

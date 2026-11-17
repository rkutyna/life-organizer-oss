"""Keep the op queue honest when a change is reverted from History.

Registered with `app.audit.register_revert_hook` when the reminders models are imported.

An op's fields after it was queued (state, applied_at, ext_id, error, attempts, ...) record what
its applier did at the provider. Setting one back does not undo that: reverting `state` from
applied to pending would apply the op a second time, and reverting `ext_id` would detach the
reminder from its provider id. So every such revert is refused. To undo a change, change the
reminder again; to drop a queued op, withdraw it on the Reminders page (or revert its create).

Restoring a withdrawn op (reverting its delete) is refused when its reminder is gone or is no
longer the reminder the op was queued for (`sync.target_matches`).
"""

from sqlalchemy.orm import Session

from app import audit
from app.db import OwnedMixin
from app.modules.reminders import sync
from app.modules.reminders.models import Reminder, ReminderOp


def after_op_revert(
    session: Session, change: audit.ChangeLog, obj: OwnedMixin, author: str
) -> None:
    if change.op == "update":
        raise audit.RevertConflict(
            f"a reminder change's '{change.field}' records what its applier did and cannot be "
            "set back; change the reminder again, or withdraw a queued change"
        )
    if change.op == "delete" and isinstance(obj, ReminderOp):
        if obj.state == "applied":
            return
        row = session.get(Reminder, obj.reminder_id)
        if not sync.target_matches(obj, row):
            raise audit.RevertConflict(sync.STALE_TARGET)


audit.register_revert_hook(ReminderOp.__tablename__, after_op_revert)

"""Claim statuses (V7) that count as open. denied and withdrawn are closed.
approved stays open: the claim is still being paid, and staff may need to
check identity on a payment.

Its own module so the app (demo_seed) and the vault (ssn/store) share it
without the app importing any SSN code.
"""

OPEN_CLAIM_STATUSES = ("submitted", "in_review", "approved")

# Claim-Sense

Link to the Video - https://drive.google.com/file/d/1Yav1BQgXfwORmlMgmKCIaMZ2DDfp5IDl/view?usp=sharing


# ClaimSense - Detailed Solution Overview

ClaimSense transforms warranty approvals using AI on Salesforce. Dealers submit claims via Web chat or Portal, get instant approval predictions, structured claim creation, Slack-based approvals, and proactive fleet anomaly detection-turning claims into early signals that prevent costly recalls.

# The Problem

Dealers submit warranty prior-authorization requests over email. Three OEM approvers must manually open attachments, validate coverage, cross-check history, and type decisions. Average resolution time: 3 days. Dealers wait. Repairs stall. Borderline claims get rushed approvals. Meanwhile, every claim a signal of potential fleet-wide failure - silently dies in an inbox.

# Two Agentforce Patterns Working Together

DealerAssist - Conversational External Agent

Experience Cloud + Salesforce Mobile

DealerAssist is embedded in an Experience Cloud dealer site and meets dealers where they already work. Dealers initiate a prior-authorization request conversationally by providing the VIN and replacement part number.

Before submission, a ClaimPredict insight card surfaces:

· Historical approval probability for that part and vehicle

· Expected payout range

· Plain-English reasoning based on prior claims

This is actionable intelligence - not a rubber stamp - helping dealers decide whether a repair is worth proceeding with. When the claim is submitted, it is automatically created as a structured record in Salesforce Automotive Cloud.

At this moment, a custom Slack notification is automatically sent to the warranty adjudication channel, alerting the OEM team that a new claim is ready for review -replacing inbox polling with real-time awareness.

Approved outcomes are delivered instantly to the dealer via Salesforce Mobile notifications.

---

# Fleet-Wide Anomaly Detection

Fleet anomaly detection runs via scheduled automation that continuously evaluates recent warranty claim volumes by part and vehicle model. When predefined thresholds are exceeded:

· An engineering investigation case is automatically created

· All related claims are flagged

· OEM stakeholders are notified

This occurs without manual review, enabling early detection of manufacturing defects.

---

# ClaimSense Slack Agent - Internal Ambient Agent

Slack + Semantic Intelligence

For approvers, ClaimSense lives entirely in Slack. Upon claim creation, the adjudicator receives an enriched Slack notification containing:

· Warranty coverage status

· Vehicle and dealer history

· Prior failures of the same part

· Fleet benchmarks

· Semantic memory retrieved from similar past adjudications

Every historical approval and rationale is extracted using Prompt Builder, converted into semantic vectors, and stored in Data Cloud. When a similar claim appears, the agent retrieves precedent by meaning, not keywords, surfacing insights such as:

“Thermal seal failure consistent with March–June 2023 batch. Prior recommendation: approve and escalate.”

Typing a single sentence - “Approve claim 847” - triggers four actions:

1. Claim approved in Automotive Cloud

2. Dealer notified on Salesforce Mobile

3. Engineering case updated

4. Institutional memory enriched for future decisions

The adjudicator never opens a Salesforce tab.

---

# The Outcome

· Manufacturing batch defect detected 6 weeks early

· Targeted service bulletin issued instead of a fleet-wide recall

· ₹45 crore recall averted

· Faster approvals, higher dealer confidence, and a system that learns with every claim processed
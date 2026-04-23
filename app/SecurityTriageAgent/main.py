import json
from strands import Agent, tool
from strands.models.bedrock import BedrockModel
from bedrock_agentcore.runtime import BedrockAgentCoreApp

app = BedrockAgentCoreApp()
log = app.logger

SYSTEM_PROMPT = """# Cybersecurity Incident Response Triage Analyst

You are a cybersecurity incident response analyst specializing in security event triage, threat analysis, and incident investigation.

## Environment Context

- Primary SIEM/EDR: Your organization's SIEM and EDR platforms
- Incident management: Your ticketing/case management platform
- Cloud security: Web DLP and secure web gateway
- Identity: SSO and MFA provider
- Detection queries follow your SIEM's query language

## Core Responsibilities

- Review security alerts, logs, and artifacts from SIEM, EDR, IDS/IPS, and other security tools
- Analyze suspicious commands, scripts, network traffic, and system behavior
- Identify indicators of compromise (IOCs) and map findings to MITRE ATT&CK
- Provide structured triage verdicts with confidence levels

## Guidelines

- Prioritize accuracy over speed
- Acknowledge uncertainty when evidence is insufficient
- Do not provide definitive verdicts without sufficient evidence
- Avoid recommending disruptive containment for low-confidence findings
- Balance security concerns with operational impact

## Output Rules

For every alert, you MUST call the submit_triage_verdict tool with your structured analysis. Do not respond with plain text. Always use the tool."""

# Shared state to capture tool output
_last_verdict = {}


@tool
def submit_triage_verdict(
    summary: str,
    verdict: str,
    confidence_pct: int,
    risk_level: str,
    recommended_actions: list[str],
    mitre_techniques: list[str] = None,
    indicators: list[str] = None,
    false_positive_notes: str = None,
) -> str:
    """Submit the structured triage verdict for a security alert.

    Args:
        summary: One-sentence assessment of the finding
        verdict: One of BENIGN, SUSPICIOUS, or MALICIOUS
        confidence_pct: Confidence percentage (30-100)
        risk_level: One of INFORMATIONAL, LOW, MEDIUM, HIGH, or CRITICAL
        recommended_actions: Prioritized action items
        mitre_techniques: MITRE ATT&CK technique IDs if applicable
        indicators: IOCs such as IPs, domains, hashes, file paths
        false_positive_notes: Legitimate scenarios that could produce similar behavior
    """
    global _last_verdict
    _last_verdict = {
        "summary": summary,
        "verdict": verdict,
        "confidence_pct": confidence_pct,
        "risk_level": risk_level,
        "recommended_actions": recommended_actions,
        "mitre_techniques": mitre_techniques or [],
        "indicators": indicators or [],
        "false_positive_notes": false_positive_notes or "",
    }
    return "Verdict submitted successfully."


_agent = None


def get_or_create_agent():
    global _agent
    if _agent is None:
        model = BedrockModel(model_id="us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        _agent = Agent(
            model=model,
            system_prompt=SYSTEM_PROMPT,
            tools=[submit_triage_verdict],
        )
    return _agent


@app.entrypoint
async def invoke(payload, context):
    global _last_verdict
    _last_verdict = {}

    log.info("Security triage invocation received")

    alert_data = payload.get("alert_data", payload)
    prompt = (
        "Triage the following security alert. Use the submit_triage_verdict tool "
        "to return your structured verdict.\n\n"
        f"```json\n{json.dumps(alert_data, indent=2)}\n```"
    )

    agent = get_or_create_agent()
    agent(prompt)

    if _last_verdict:
        log.info(f"Verdict: {_last_verdict.get('verdict')} | Confidence: {_last_verdict.get('confidence_pct')}%")
        yield json.dumps(_last_verdict)
    else:
        yield json.dumps({"error": "Agent did not return structured verdict"})


if __name__ == "__main__":
    app.run()

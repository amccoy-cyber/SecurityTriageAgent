# SecurityTriageAgent

A proof-of-concept security triage agent deployed on [Amazon Bedrock AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/what-is-bedrock-agentcore.html). It accepts raw security alert payloads (e.g., from your EDR or SOAR platform) via an API Gateway endpoint and returns structured JSON verdicts, including severity, MITRE ATT&CK mappings, IOCs, and recommended actions.

This agent was originally developed and refined locally using [Kiro CLI](https://kiro.dev/), then ported to AgentCore Runtime for centralized, cloud-hosted access by external security platforms.

---

## Quickstart

Clone the repo and deploy in a few minutes.

### Prerequisites

- AWS CLI configured with valid credentials
- Node.js 20+ (`nvm install --lts`)
- Python 3.10+
- AWS CDK (`npm install -g aws-cdk`)
- AgentCore CLI (`npm install -g @aws/agentcore`)
- CDK bootstrapped: `cdk bootstrap aws://YOUR_ACCOUNT_ID/us-east-1`
- Claude Sonnet model access enabled in the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess)

### Deploy

```bash
git clone https://github.com/amccoy-cyber/SecurityTriageAgent.git
cd SecurityTriageAgent
```

Edit `agentcore/aws-targets.json` with your account ID:

```json
[
  {
    "name": "default",
    "account": "YOUR_ACCOUNT_ID",
    "region": "us-east-1"
  }
]
```

Test locally first:

```bash
agentcore dev
```

In another terminal:

```bash
curl -s -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{"alert_data": {"detection_name": "Suspicious PowerShell Download Cradle", "severity": "High", "hostname": "WORKSTATION-42", "username": "jsmith"}}'
```

Deploy to AWS:

```bash
agentcore deploy -y
```

Invoke the deployed agent:

```bash
agentcore invoke --runtime SecurityTriageAgent '{"alert_data": {"detection_name": "Suspicious PowerShell Download Cradle", "severity": "High", "hostname": "WORKSTATION-42", "username": "jsmith"}}'
```

That's it. The agent is live and you can invoke it from the CLI. To expose it as an HTTPS endpoint that external tools can call with an API key, see the [API Gateway Setup](#api-gateway-setup) section below.

---

## Architecture

```
Security Alert (EDR / SIEM / SOAR)
        │
        ▼  HTTPS POST + API Key
┌──────────────────────┐
│   API Gateway (REST)  │  ← API key auth, rate limiting, usage plan
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│   Lambda Proxy        │  ← Calls InvokeAgentRuntime, parses SSE response
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│  AgentCore Runtime    │  ← Managed serverless runtime (microVM)
│  ┌────────────────┐  │
│  │ Strands Agent   │  │  ← System prompt + submit_triage_verdict tool
│  │ Claude Sonnet   │  │
│  └────────────────┘  │
└──────────────────────┘
           │
           ▼
    Structured JSON Verdict
```

## Project Structure

```
SecurityTriageAgent/
├── app/
│   └── SecurityTriageAgent/
│       ├── main.py              # Agent entrypoint (Strands + tool definition)
│       └── pyproject.toml       # Python dependencies
├── agentcore/
│   ├── agentcore.json           # AgentCore project config
│   ├── aws-targets.json         # Deployment target (account + region)
│   ├── cdk/                     # CDK infrastructure (auto-managed)
│   └── .env.local               # Local env vars (gitignored)
└── README.md
```

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | 2.x | [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Node.js | 20+ | `nvm install --lts` |
| Python | 3.10+ | System default on Ubuntu 22.04+ |
| AWS CDK | 2.x | `npm install -g aws-cdk` |
| AgentCore CLI | 0.9+ | `npm install -g @aws/agentcore` |

You also need:
- AWS credentials configured (`aws configure`)
- CDK bootstrapped in your target region: `cdk bootstrap aws://ACCOUNT_ID/REGION`
- Claude Sonnet model access enabled in the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess)

## How the Agent Works

### System Prompt

The agent is configured as a cybersecurity IR triage analyst. The system prompt includes:
- Role definition (IR analyst specializing in triage)
- Environment context (your SIEM, EDR, identity provider, etc.)
- Analysis guidelines (accuracy over speed, acknowledge uncertainty)
- Output rules (must use the `submit_triage_verdict` tool — no freeform text)

### Structured Output via Tool Use

Instead of returning freeform text, the agent is forced to call a `submit_triage_verdict` tool. This guarantees a consistent JSON schema on every invocation:

```json
{
  "summary": "One-sentence assessment",
  "verdict": "BENIGN | SUSPICIOUS | MALICIOUS",
  "confidence_pct": 95,
  "risk_level": "INFORMATIONAL | LOW | MEDIUM | HIGH | CRITICAL",
  "recommended_actions": ["Isolate host", "Review logs", "..."],
  "mitre_techniques": ["T1059.001", "T1105"],
  "indicators": ["192.168.1.50", "payload.ps1"],
  "false_positive_notes": "Explanation of legitimate scenarios"
}
```

This is the same tool-use pattern from the [Bedrock Converse API](https://docs.aws.amazon.com/bedrock/latest/userguide/tool-use.html), but implemented through the [Strands Agents SDK](https://strandsagents.com/) `@tool` decorator.

### Example Output

Here's an actual response from the agent when given a PowerShell download cradle alert:

```json
{
  "summary": "Malicious PowerShell download cradle detected using obfuscation and hidden execution to download and execute remote payload",
  "verdict": "MALICIOUS",
  "confidence_pct": 95,
  "risk_level": "HIGH",
  "recommended_actions": [
    "Immediately isolate WORKSTATION-42 from the network",
    "Investigate IP 192.168.1.50 for compromise",
    "Conduct forensic analysis of WORKSTATION-42",
    "Reset credentials for jsmith",
    "Hunt for similar PowerShell patterns across the environment"
  ],
  "mitre_techniques": ["T1059.001", "T1105", "T1027", "T1140"],
  "indicators": ["192.168.1.50", "http://192.168.1.50/payload.ps1", "WORKSTATION-42", "jsmith"],
  "false_positive_notes": "Extremely unlikely. Legitimate scripts would not use hidden windows, encoded commands, and download from a file named payload.ps1."
}
```

### Model

Uses `us.anthropic.claude-sonnet-4-5-20250929-v1:0` — the US inference profile for Claude Sonnet 4.5. The `us.` prefix routes to US-based endpoints for lower latency.

> **Note:** You cannot use raw model IDs (e.g., `anthropic.claude-sonnet-4-5-20250929-v1:0`) for on-demand invocation. You must use an inference profile prefix (`us.`, `global.`, etc.). Check available profiles with:
> ```bash
> aws bedrock list-inference-profiles --region us-east-1 \
>   --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'sonnet')].{id:inferenceProfileId,name:inferenceProfileName}" \
>   --output table
> ```

## Deployment Walkthrough

### 1. Scaffold the Project

```bash
npm install -g @aws/agentcore
agentcore create --name SecurityTriageAgent --framework Strands --protocol HTTP --model-provider Bedrock --memory none
cd SecurityTriageAgent
```

### 2. Configure the Deployment Target

Edit `agentcore/aws-targets.json`:

```json
[
  {
    "name": "default",
    "account": "YOUR_ACCOUNT_ID",
    "region": "us-east-1"
  }
]
```

The `name` field must be `"default"` unless you explicitly pass `--target` to the CLI.

### 3. Write Your Agent Code

Replace the generated `app/SecurityTriageAgent/main.py` with your agent logic. Key patterns:

- **`BedrockAgentCoreApp()`** — the runtime wrapper that handles HTTP serving
- **`@tool`** — Strands decorator to define tools the model can call
- **`@app.entrypoint`** — the async handler that receives payloads and yields responses
- **`Agent(model=..., system_prompt=..., tools=[...])`** — the Strands agent

See `app/SecurityTriageAgent/main.py` for the full implementation.

### 4. Test Locally

```bash
agentcore dev
```

This starts a local Uvicorn server on port 8080 (or next available port) with hot-reload. In another terminal:

```bash
curl -s -X POST http://localhost:8080/invocations \
  -H "Content-Type: application/json" \
  -d '{
    "alert_data": {
      "detection_name": "Suspicious PowerShell Download Cradle",
      "severity": "High",
      "hostname": "WORKSTATION-42",
      "username": "jsmith",
      "command_line": "powershell.exe -nop -w hidden -enc ...",
      "sensor": "EDR"
    }
  }'
```

### 5. Deploy to AgentCore Runtime

```bash
agentcore deploy -y
```

This uses CDK under the hood to create:
- An AgentCore Runtime (managed microVM)
- An IAM role for the runtime
- S3 assets for the code package

Verify with:

```bash
agentcore status
```

Test the deployed agent:

```bash
agentcore invoke --runtime SecurityTriageAgent '{"alert_data":{...}}'
```

### 6. Expose via API Gateway (Optional)

To allow external tools like your SOAR platform to call the agent, set up:

1. **Lambda proxy** — calls `InvokeAgentRuntime` via boto3 and parses the SSE response
2. **REST API Gateway** — with API key authentication and a usage plan
3. **Usage plan** — rate limiting and daily quota

See the [API Gateway Setup](#api-gateway-setup) section below for details.

## API Gateway Setup

To expose the agent as an HTTPS endpoint with API key authentication, run the setup script. It creates a Lambda proxy, REST API Gateway, API key, and usage plan automatically.

Make sure you've deployed the agent first (`agentcore deploy -y`), then:

```bash
./api-gateway/setup.sh
```

The script will:
1. Detect your AgentCore Runtime ARN from `agentcore status`
2. Package and deploy the Lambda proxy (`api-gateway/lambda_function.py`)
3. Create a REST API Gateway with a `/triage` POST endpoint
4. Create an API key with rate limiting (2 req/sec, 100/day)
5. Print your endpoint URL and API key

Test it:

```bash
curl -X POST https://YOUR_API_ID.execute-api.us-east-1.amazonaws.com/prod/triage \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{
    "alert_data": {
      "detection_name": "Suspicious PowerShell Download Cradle",
      "severity": "High",
      "hostname": "WORKSTATION-42",
      "username": "jsmith",
      "sensor": "EDR"
    }
  }'
```

## Cost Considerations

AgentCore Runtime uses consumption-based pricing — you only pay for active CPU and memory. I/O wait (waiting for the LLM response) is free.

| Resource | Rate |
|----------|------|
| Runtime CPU | $0.0895 / vCPU-hour |
| Runtime Memory | $0.00945 / GB-hour |
| Lambda | Free tier covers ~1M requests/month |
| API Gateway | Free tier covers 1M API calls/month |
| Bedrock (Claude Sonnet) | Per-token pricing ([see Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)) |

For a PoC with a handful of test calls, total cost is negligible — cents at most.

## Cleanup

To tear down all AgentCore resources:

```bash
cd SecurityTriageAgent
agentcore remove all
agentcore deploy
```

To remove the API Gateway layer:

```bash
aws apigateway delete-rest-api --rest-api-id YOUR_API_ID --region us-east-1
aws lambda delete-function --function-name SecurityTriageProxy --region us-east-1
aws iam delete-role-policy --role-name SecurityTriageProxy-Lambda --policy-name AgentCoreInvoke
aws iam detach-role-policy --role-name SecurityTriageProxy-Lambda --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name SecurityTriageProxy-Lambda
```

## Future Enhancements

- **Multi-agent orchestration** - Chain triage, enrichment, and response agents together
- **OAuth** - Graduate from API keys to OAuth via AgentCore Identity
- **WAF** - IP allowlisting for known consumer egress IPs

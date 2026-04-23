import json
import uuid
import boto3

# NOTE: The ARN below is automatically injected by setup.sh at deploy time.
# You do not need to edit this manually if you use the setup script.
AGENT_ARN = "YOUR_AGENTCORE_RUNTIME_ARN"
client = boto3.client("bedrock-agentcore", region_name="us-east-1")


def handler(event, context):
    try:
        body = json.loads(event.get("body", "{}"))
        payload = json.dumps({"prompt": "", "alert_data": body.get("alert_data", body)}).encode()

        response = client.invoke_agent_runtime(
            agentRuntimeArn=AGENT_ARN,
            runtimeSessionId=str(uuid.uuid4()),
            payload=payload,
            qualifier="DEFAULT",
        )

        chunks = [chunk.decode("utf-8") for chunk in response.get("response", [])]
        raw = "".join(chunks)

        for line in raw.strip().split("\n"):
            line = line.strip()
            if line.startswith("data: "):
                line = line[6:]
            if not line:
                continue
            try:
                parsed = json.loads(line)
                if isinstance(parsed, str):
                    parsed = json.loads(parsed)
                return {"statusCode": 200, "headers": {"Content-Type": "application/json"}, "body": json.dumps(parsed)}
            except (json.JSONDecodeError, TypeError):
                continue

        return {"statusCode": 502, "body": json.dumps({"error": "No parseable response"})}

    except Exception as e:
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}

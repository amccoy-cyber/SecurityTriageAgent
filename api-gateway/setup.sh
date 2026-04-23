#!/bin/bash
set -e

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get the AgentCore Runtime ARN
echo "Fetching AgentCore Runtime ARN..."
RUNTIME_ARN=$(cd "$SCRIPT_DIR/.." && agentcore status 2>&1 | grep -oP 'arn:aws:bedrock-agentcore[^\s\)]+')

if [ -z "$RUNTIME_ARN" ]; then
    echo "ERROR: Could not find AgentCore Runtime ARN. Make sure you've run 'agentcore deploy' first."
    exit 1
fi

echo "Runtime ARN: $RUNTIME_ARN"

# Inject the ARN into the Lambda code
echo "Packaging Lambda..."
TEMP_DIR=$(mktemp -d)
sed "s|YOUR_AGENTCORE_RUNTIME_ARN|$RUNTIME_ARN|g" "$SCRIPT_DIR/lambda_function.py" > "$TEMP_DIR/lambda_function.py"
cd "$TEMP_DIR" && zip -j lambda.zip lambda_function.py > /dev/null

# Create IAM role
echo "Creating IAM role..."
aws iam create-role \
    --role-name SecurityTriageProxy-Lambda \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --region $REGION > /dev/null 2>&1 || echo "Role already exists, continuing..."

aws iam attach-role-policy \
    --role-name SecurityTriageProxy-Lambda \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam put-role-policy \
    --role-name SecurityTriageProxy-Lambda \
    --policy-name AgentCoreInvoke \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"bedrock-agentcore:InvokeAgentRuntime\",\"Resource\":[\"$RUNTIME_ARN\",\"$RUNTIME_ARN/*\"]}]}"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/SecurityTriageProxy-Lambda"
echo "Waiting for IAM propagation..."
sleep 10

# Create Lambda
echo "Creating Lambda function..."
aws lambda create-function \
    --function-name SecurityTriageProxy \
    --runtime python3.12 \
    --handler lambda_function.handler \
    --role "$ROLE_ARN" \
    --zip-file "fileb://$TEMP_DIR/lambda.zip" \
    --timeout 120 \
    --memory-size 256 \
    --region $REGION > /dev/null 2>&1 || \
aws lambda update-function-code \
    --function-name SecurityTriageProxy \
    --zip-file "fileb://$TEMP_DIR/lambda.zip" \
    --region $REGION > /dev/null

# Create API Gateway
echo "Creating API Gateway..."
API_ID=$(aws apigateway create-rest-api \
    --name SecurityTriageAPI \
    --endpoint-configuration types=REGIONAL \
    --region $REGION \
    --query 'id' --output text)

ROOT_ID=$(aws apigateway get-resources --rest-api-id $API_ID --region $REGION --query 'items[0].id' --output text)

RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id $API_ID \
    --parent-id $ROOT_ID \
    --path-part triage \
    --region $REGION \
    --query 'id' --output text)

aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $RESOURCE_ID \
    --http-method POST \
    --authorization-type NONE \
    --api-key-required \
    --region $REGION > /dev/null

LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:SecurityTriageProxy"

aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $RESOURCE_ID \
    --http-method POST \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" \
    --region $REGION > /dev/null

aws lambda add-permission \
    --function-name SecurityTriageProxy \
    --statement-id apigateway-invoke \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/POST/triage" \
    --region $REGION > /dev/null

aws apigateway create-deployment \
    --rest-api-id $API_ID \
    --stage-name prod \
    --region $REGION > /dev/null

# Create API key and usage plan
echo "Creating API key and usage plan..."
PLAN_ID=$(aws apigateway create-usage-plan \
    --name SecurityTriagePlan \
    --throttle burstLimit=5,rateLimit=2 \
    --quota limit=100,period=DAY \
    --api-stages apiId=$API_ID,stage=prod \
    --region $REGION \
    --query 'id' --output text)

KEY_ID=$(aws apigateway create-api-key \
    --name TriageKey \
    --enabled \
    --region $REGION \
    --query 'id' --output text)

KEY_VALUE=$(aws apigateway get-api-key \
    --api-key $KEY_ID \
    --include-value \
    --region $REGION \
    --query 'value' --output text)

aws apigateway create-usage-plan-key \
    --usage-plan-id $PLAN_ID \
    --key-id $KEY_ID \
    --key-type API_KEY \
    --region $REGION > /dev/null

# Cleanup temp
rm -rf "$TEMP_DIR"

echo ""
echo "========================================="
echo "  API Gateway deployed successfully!"
echo "========================================="
echo ""
echo "  Endpoint: https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/triage"
echo "  API Key:  ${KEY_VALUE}"
echo ""
echo "  Test with:"
echo "  curl -X POST https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod/triage \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'x-api-key: ${KEY_VALUE}' \\"
echo "    -d '{\"alert_data\": {\"detection_name\": \"Test Alert\", \"severity\": \"High\"}}'"
echo ""

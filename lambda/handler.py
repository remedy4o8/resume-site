"""
Andy Pham — Resume Site Chatbot
AWS Lambda handler · Python 3.12

Architecture:
  API Gateway POST /chat  →  this Lambda  →  Amazon Bedrock (Claude Haiku)

The Lambda reads context.md from S3 on cold start and uses it as the
system prompt so the chatbot knows everything about Andy.

Environment variables (set in Lambda console or Terraform):
  BUCKET_NAME   — S3 bucket where context.md is stored (same bucket as the site)
  CONTEXT_KEY   — S3 key for the context file (default: "context.md")
  MODEL_ID      — Bedrock model ID (default: "us.anthropic.claude-haiku-4-5-20251001")
  ALLOWED_ORIGIN — CORS origin, e.g. "https://andytangpham.com" (default: "*")
"""

import json
import os
import boto3
from botocore.exceptions import ClientError

# ── AWS clients (initialized once at cold start) ──────────────────────────────
s3_client      = boto3.client("s3")
bedrock_client = boto3.client("bedrock-runtime", region_name="us-east-1")

# ── Config from environment variables ─────────────────────────────────────────
BUCKET_NAME    = os.environ.get("BUCKET_NAME", "YOUR-BUCKET-NAME")
CONTEXT_KEY    = os.environ.get("CONTEXT_KEY", "context.md")
MODEL_ID       = os.environ.get("MODEL_ID",    "us.anthropic.claude-haiku-4-5-20251001")
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "*")

# Max tokens for the chatbot response (keep short for a resume chatbot)
MAX_TOKENS     = 512

# ── Cache the context in memory after first load (lives for Lambda lifetime) ──
_context_cache: str | None = None


def load_context() -> str:
    """Load context.md from S3. Cached in memory after first call."""
    global _context_cache
    if _context_cache is not None:
        return _context_cache

    try:
        response = s3_client.get_object(Bucket=BUCKET_NAME, Key=CONTEXT_KEY)
        _context_cache = response["Body"].read().decode("utf-8")
        print(f"[cold start] Loaded context from s3://{BUCKET_NAME}/{CONTEXT_KEY} "
              f"({len(_context_cache)} chars)")
    except ClientError as e:
        print(f"[error] Could not load context from S3: {e}")
        # Fall back to a minimal hardcoded prompt so the bot still works
        _context_cache = (
            "You are the AI assistant for Andy Pham's resume website. "
            "Andy is a Systems Administrator based in San Jose, CA with 10+ years of IT experience. "
            "Answer questions about his skills, experience, and availability."
        )

    return _context_cache


def build_system_prompt(context: str) -> str:
    """Wrap the raw context in a structured system prompt."""
    return f"""You are Andy Pham's AI assistant on his personal resume website.
Your job is to help recruiters, hiring managers, and collaborators learn about Andy.

RULES:
- Only answer questions about Andy Pham — his skills, experience, background, availability, and projects.
- If asked something completely unrelated (e.g. "write me a poem about cats"), politely redirect.
- Be friendly, professional, and concise. Recruiters are busy.
- If you don't know the answer, say so honestly — don't make things up.
- Keep answers to 2–4 sentences unless a detailed answer is genuinely needed.
- You may encourage the visitor to email Andy at andytangpham@gmail.com for anything specific.

EVERYTHING YOU KNOW ABOUT ANDY:
{context}
"""


def cors_headers() -> dict:
    return {
        "Access-Control-Allow-Origin":  ALLOWED_ORIGIN,
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Content-Type": "application/json",
    }


def lambda_handler(event: dict, context) -> dict:
    """
    Expected request body: { "message": "user's question" }
    Response body:         { "reply": "bot's answer" }
    """

    # ── Handle CORS preflight ──────────────────────────────────────────────────
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return {"statusCode": 200, "headers": cors_headers(), "body": ""}

    # ── Parse incoming message ─────────────────────────────────────────────────
    try:
        body = json.loads(event.get("body") or "{}")
        user_message = body.get("message", "").strip()
    except (json.JSONDecodeError, AttributeError):
        return {
            "statusCode": 400,
            "headers": cors_headers(),
            "body": json.dumps({"error": "Invalid JSON body"}),
        }

    if not user_message:
        return {
            "statusCode": 400,
            "headers": cors_headers(),
            "body": json.dumps({"error": "message field is required"}),
        }

    # Basic length guard — prevent abuse
    if len(user_message) > 1000:
        return {
            "statusCode": 400,
            "headers": cors_headers(),
            "body": json.dumps({"error": "Message too long (max 1000 chars)"}),
        }

    # ── Call Bedrock ───────────────────────────────────────────────────────────
    system_prompt = build_system_prompt(load_context())

    try:
        response = bedrock_client.invoke_model(
            modelId=MODEL_ID,
            contentType="application/json",
            accept="application/json",
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": MAX_TOKENS,
                "system": system_prompt,
                "messages": [
                    {"role": "user", "content": user_message}
                ],
            }),
        )

        result   = json.loads(response["body"].read())
        reply    = result["content"][0]["text"]

        print(f"[chat] Q: {user_message[:80]} | A: {reply[:80]}")

        return {
            "statusCode": 200,
            "headers": cors_headers(),
            "body": json.dumps({"reply": reply}),
        }

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        print(f"[bedrock error] {error_code}: {e}")

        if error_code == "AccessDeniedException":
            msg = "Bedrock access not enabled. Enable Claude Haiku in the Bedrock console for this region."
        elif error_code == "ThrottlingException":
            msg = "Rate limit hit — try again in a moment."
        else:
            msg = "Something went wrong on my end. Try again shortly."

        return {
            "statusCode": 500,
            "headers": cors_headers(),
            "body": json.dumps({"reply": msg}),
        }

    except Exception as e:
        print(f"[unexpected error] {e}")
        return {
            "statusCode": 500,
            "headers": cors_headers(),
            "body": json.dumps({"reply": "Unexpected error. Please try again."}),
        }

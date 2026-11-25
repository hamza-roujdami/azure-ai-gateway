"""HTTP front for the agent: POST /chat {"message": "..."} -> {"answer": "..."}.

Ingress is internal to the Container Apps environment, so only workloads in the environment can call it.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from azure.identity import DefaultAzureCredential
from fastapi import FastAPI
from pydantic import BaseModel, Field

from gateway_agent import Settings, open_agent


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)


class ChatResponse(BaseModel):
    answer: str


async def run_agent(message: str) -> str:
    async with open_agent(app.state.settings, app.state.credential) as agent:
        result = await agent.run(message)
    return result.text


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.settings = Settings()
    app.state.credential = DefaultAzureCredential()
    yield
    app.state.credential.close()


app = FastAPI(title="orders-agent", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict:
    return {"status": "ok"}


@app.post("/chat")
async def chat(request: ChatRequest) -> ChatResponse:
    return ChatResponse(answer=await run_agent(request.message))

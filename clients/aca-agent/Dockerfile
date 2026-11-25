FROM python:3.13-slim
WORKDIR /app
RUN useradd --create-home --uid 10001 app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY gateway_agent.py app.py smoke.py ask.py ./
USER 10001
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

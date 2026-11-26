FROM python:3.13-slim
WORKDIR /app
RUN useradd --create-home --uid 10001 app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY orders.py server.py me_server.py ./
USER 10001
EXPOSE 8000
CMD ["python", "server.py"]

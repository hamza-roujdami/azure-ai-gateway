FROM python:3.13-slim
WORKDIR /app
RUN useradd --create-home --uid 10001 app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shipping.py ./
USER 10001
EXPOSE 8000
CMD ["uvicorn", "shipping:app", "--host", "0.0.0.0", "--port", "8000"]

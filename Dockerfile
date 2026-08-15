FROM python:3.12-slim

# git is needed to install the speedhive-tools git dependency
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server/ server/

EXPOSE 8321
CMD ["python", "server/app.py"]

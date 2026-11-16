FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
WORKDIR /opt/okdocker
COPY client.py ./client.py
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
CMD ["python3", "-I", "/opt/okdocker/client.py"]

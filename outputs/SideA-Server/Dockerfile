FROM python:3.12-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 SIDEA_STATE=/data
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 12040 --no-create-home --shell /usr/sbin/nologin sidea && install -d -m 0700 -o sidea -g sidea /data
COPY catalog.py qq_provider.py kuwo_provider.py device_library.py server.py ./
COPY templates ./templates
COPY static ./static
USER sidea
EXPOSE 8799
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "from urllib.request import urlopen; urlopen('http://127.0.0.1:8799/health',timeout=3)"
CMD ["waitress-serve","--listen=0.0.0.0:8799","--threads=12","--trusted-proxy=127.0.0.1","--call","server:make_app"]

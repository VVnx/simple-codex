FROM python:3.12-slim
RUN pip install --no-cache-dir qrcode==8.2
RUN useradd --uid 10001 --create-home bridge && mkdir /data && chown bridge:bridge /data
WORKDIR /app
COPY cloud/bridge.py cloud/enroll.py /app/
USER 10001:10001
ENV PYTHONUNBUFFERED=1 BRIDGE_STATE_DIR=/data
VOLUME ["/data"]
ENTRYPOINT ["python", "/app/bridge.py"]
CMD ["run"]

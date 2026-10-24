# Hardening: pin the base by digest (python:3.13-slim@sha256:...).
FROM python:3.13-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
# pip is only needed to build the venv, so it is removed once the packages are
# in. It carries vendored copies of urllib3, setuptools and msgpack that Trivy
# flags, and the running app never calls it.
RUN python -m venv /venv && /venv/bin/pip install --require-virtualenv -r requirements.txt \
 && /venv/bin/pip uninstall --yes pip

FROM python:3.13-slim
ARG APP_VERSION=dev
ENV PATH=/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/srv/src \
    APP_VERSION=${APP_VERSION} \
    PORT=8000
# Same for the base image's own pip. /venv isn't copied in yet, so this is
# the system Python.
RUN /usr/local/bin/python -m pip uninstall --yes pip \
 && groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
COPY --from=build /venv /venv
COPY src/ /srv/src/
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD python -c "import os,urllib.request;urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/health',timeout=2)" || exit 1
CMD ["sh", "-c", "exec uvicorn demo_app.main:app --host 0.0.0.0 --port ${PORT} --no-access-log --proxy-headers"]

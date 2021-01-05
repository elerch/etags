FROM python:3.8.7-alpine3.12

WORKDIR /app
ENTRYPOINT ["etags.py"]

COPY requirements.txt /app/
COPY etags.py /app/

RUN pip3 install -r requirements.txt && rm /app/requirements.txt

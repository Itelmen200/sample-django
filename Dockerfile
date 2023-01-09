FROM python:3.9-buster

WORKDIR /app
ENV DJANGO_ALLOWED_HOSTS=192.168.10.117,localhost
ENV DATABASE_URL="postgres://postgres:postgres@terraform-20230109194437418600000001.c1stjbzmb3ve.eu-central-1.rds.amazonaws.com:5432/postgres"
ENV DEBUG="False"
COPY . .
RUN pip install -r requirements.txt --no-cache-dir
CMD python manage.py migrate && python manage.py runserver 0.0.0.0:80
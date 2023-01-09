FROM python:3.9-buster

WORKDIR /app
ENV DJANGO_ALLOWED_HOSTS=192.168.10.117,localhost
ENV DATABASE_URL="postgres://postgresUser:postgresPW@172.17.0.2/postgresDB"
ENV DEBUG="False"
# ARG DATABASE_URL="postgresql://<PRIVATE_IP>/<DATABASE>?user=<USER>"
COPY . .
RUN pip install -r requirements.txt --no-cache-dir
RUN python manage.py migrate
CMD python manage.py runserver 0.0.0.0:8000
EXPOSE 8000
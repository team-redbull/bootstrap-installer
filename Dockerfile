FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Terraform (committed binary for linux/amd64)
COPY utils_bin/terraform_1.14.6_linux_amd64.zip /tmp/
RUN unzip /tmp/terraform_1.14.6_linux_amd64.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/terraform \
    && rm /tmp/terraform_1.14.6_linux_amd64.zip

# ArgoCD (committed binary)
COPY utils_bin/argocd-linux-amd64 /usr/local/bin/argocd
RUN chmod +x /usr/local/bin/argocd

# OCP binaries — download from your mirror and place in bin/ before building:
#   bin/openshift-install-4.20
#   bin/oc
COPY bin/openshift-install-4.20 /usr/local/bin/openshift-install-4.20
COPY bin/oc /usr/local/bin/oc
RUN chmod +x /usr/local/bin/openshift-install-4.20 /usr/local/bin/oc

# App
COPY . .

ENTRYPOINT ["python3", "bootstrap.py"]

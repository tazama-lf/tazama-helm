<!-- SPDX-License-Identifier: Apache-2.0 -->

# tazama-helm
Containerized deployment of the Tazama platform (tms-service) onto Kubernetes via Helm

## Helm Chart Configuration

### Pre-requisites
- [Helm 3](https://helm.sh/docs/intro/install/)
- [Kubernetes 1.31+](https://kubernetes.io/docs/setup/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [PostgreSQL 12+](https://www.postgresql.org/download/)
- [Redis 6+](https://redis.io/download/)

1. Create helm templates folder
```shell
mkdir charts

helm create charts/tms-service
```

2. Modify values.yaml in charts/tms-service to match the application.
```yaml
image:
  repository: tazama-lf/tms-service
  tag: latest
  
sidecar:
  name: sidecar
  image:
    repository: tazama-lf/sidecar
    tag: latest
  port: 5000
    
imagePullSecrets:
  - name: frmpullsecret
    
service:
  # This sets the service type more information can be found here: https://kubernetes.io/docs/concepts/services-networking/service/#publishing-services-service-types
  type: ClusterIP
  # This sets the ports more information can be found here: https://kubernetes.io/docs/concepts/services-networking/service/#field-spec-ports
  port: 3000
  
env:
  mode: "http"
  upstream_url: "http://0.0.0.0:3000"
  exec_timeout: "10s"
  write_timeout: "15s"
  read_timeout: "15s"
  prefix_logs: "false"
  FUNCTION_NAME: "transaction-monitoring-service"
  NODE_ENV: "production"
  PORT: 3000
  QUOTING: "false"
  SERVER_URL: ""
  MAX_CPU: "2"
  ...
```

3. Modify deployment.yaml in charts/tms-service/templates to include sidecar container and env variables.
```yaml
containers:
  - name: {{ .Chart.Name }}
    image: {{ .Values.image.repository }}:{{ .Values.image.tag }}   
    env:
      {{- range $key, $val := .Values.env }}
      - name: {{ $key | upper }}
        value: {{ $val | quote }}
      {{- end }}
    ports:
      - name: http
        containerPort: {{ .Values.service.port }}
        protocol: TCP    
  - name: {{ .Values.sidecar.name }}
    image: {{ .Values.sidecar.image.repository }}:{{ .Values.sidecar.image.tag }}
    imagePullPolicy: {{ .Values.sidecar.image.pullPolicy }}
    ports:
      - name: http
        containerPort: {{ .Values.sidecar.port }}
        protocol: TCP    

```

4. Modify service.yaml in charts/tms-service/templates to expose the service and sidecar port.
```yaml
...
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
    - port: {{ .Values.sidecar.port }}
      targetPort: {{ .Values.sidecar.port }}
      protocol: TCP
      name: sidecar
```

5. If the application/service requires external access, modify the ingress section in values.yaml to expose the service (provide cluster-issuer annotation for cert provisioning).
```yaml
ingress:
  enabled: true
  className: "nginx"
  annotations:
     cert-manager.io/cluster-issuer: letsencrypt-tazama-lf
  hosts:
    - host: tms-service.sandbox.tazama.lf
      paths:
        - path: /
          pathType: ImplementationSpecific
  tls:
    - secretName: tms-service-tls
      hosts:
        - tms-service.sandbox.tazama.lf
```
  


#### Helm Chart Workflows

1. Provide secret variables below in the project on GitHub.
```
DOCKER_USERNAME=
DOCKER_PASSWORD=
KUBE_CONFIG_DATA=(**base64 encoded kubeconfig data)
```

2. The `helm-package-build` workflow is triggered by a push to the main branch. 
it builds the docker image and pushes it to the dockerhub repository and then builds the helm chart and pushes it to the helm chart repository(docker hub).

3. The `helm-package-deploy` workflow is triggered manually. it deploys the helm chart to the kubernetes cluster using the kubeconfig secret variable provided in the project.

4. Before deploying the helm chart, ensure the `frmpullsecret` is created in the kubernetes cluster for pulling the images.

Create a secret with the name `frmpullsecret` with kubectl:
```shell
kubectl create secret docker-registry frmpullsecret --docker-server=https://index.docker.io/v1/ --docker-username=username --docker-password=password --docker-email=email --namespace processor
```


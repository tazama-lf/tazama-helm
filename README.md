<!-- SPDX-License-Identifier: Apache-2.0 -->

# tazama-helm

### Prerequisites
- [Helm](https://helm.sh/docs/intro/install/)
- [Helmfile](https://github.com/roboll/helmfile)
- [Kubectl](https://kubernetes.io/docs/tasks/tools/)
- Kubernetes Cluster
- Tazama Helm Charts

Containerized deployment of the Tazama platform onto Kubernetes via Helm and Helmfile.

Helm charts/release files are located in the `helmfile.d` subfolders under auxiliary, core, biar, cms, rules, etc. folders in the project root.

Modify values in the core/values, auxiliary/values, biar/values, etc. subfolders to match your environment.

Before triggering the deployment, create a docker registry secret in the `processor` namespace to allow pulling images and helm charts from the private registry (e.g. DockerHub).
```shell
kubectl create secret docker-registry frmpullsecret \
  --docker-server=docker.io --docker-username=username \
  --docker-password=password --namespace=processor
```

The `helmfile.yaml` file is the main deployment file. Run `helmfile apply --file helmfile.yaml` to deploy the platform.

Edit the `helmfiles` section in the `helmfile.yaml` file to add or exclude services from the deployment release.
```yaml
helmfiles:
  - auxiliary/helmfile.d/*.yaml
```
or
```yaml
helmfiles:
  - auxiliary/helmfile.d/*.yaml
  - core/helmfile.d/*.yaml
```


## Run locally

To install the Tazama Charts with helm, run the following at the project root
```shell
helmfile apply --file helmfile.yaml
```
To uninstall the Tazama Charts,
```shell
helmfile destroy --file helmfile.yaml
```

## Github Workflows

To trigger deployment via GitHub Actions, provide the following secrets in the project repository:
```
KUBE_CONFIG_DATA=(***base64 encoded kubeconfig file***)
DOCKER_USERNAME=
DOCKER_PASSWORD=
```

#### Disclaimer

The current setup does not include configuration management for the Tazama platform i.e., db configuration, env variables, etc.

It covers the initial deployment of the Tazama platform onto Kubernetes.
<!-- SPDX-License-Identifier: Apache-2.0 -->

# tazama-helm

### Prerequisites
- [Kubectl](https://kubernetes.io/docs/tasks/tools/)
- Kubernetes Cluster
- Tazama Helm Charts
- [Helm](https://helm.sh/docs/intro/install/) (for testing locally)
- [Helmfile](https://github.com/roboll/helmfile) (for testing locally)

Containerized deployment of the Tazama platform onto Kubernetes via Helm and Helmfile.

The folders core, auxiliary, biar, cms, datastore, etc. group the helm charts into logical groups depending on functionality. The datastore folder contains the database helmfile deployment configs, the core folder contains the core tazama services helmfile deployment configs, the auxiliary folder contains the auxiliary services helmfile deployment configs,

Helm chart definitions/release files are located in the `helmfile.d` subfolders under auxiliary, core, biar, cms, datastore, rules, etc. folders in the project root.

Modify the value files in the core/values, auxiliary/values, biar/values, etc. subfolders to match your environment.

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
Phased deployment is also supported. For example, to start with db deployment and then auxiliary and core services, update the `helmfile.yaml` file as below then trigger the deployment workflow.
```yaml
# Load values files at the top level to make them available for templating.
values:
  - ./datastore/values/*.yaml

helmfiles:
  - datastore/helmfile.d/*.yaml
```
One can proceed to update the database schemas and then deploy the auxiliary and core services by updating the `helmfile.yaml` file as below and triggering the deployment workflow.
```yaml
# Load values files at the top level to make them available for templating.
values:
  - ./datastore/values/*.yaml
  - ./auxiliary/values/*.yaml
  - ./core/values/*.yaml

helmfiles:
  - datastore/helmfile.d/*.yaml
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

The current setup does not include configuration management for the Tazama platform i.e., db configuration, env variables, etc. It covers only the initial deployment of the Tazama platform services onto Kubernetes.
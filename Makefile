# omerfsen.nvke. Run `make help` for targets.
SHELL := /bin/bash
VENV := .venv
BIN := $(VENV)/bin

.PHONY: help dev lint docs image kvm kvm-destroy build

help:
	@echo "  make dev           venv + dependencies + this repo linked as omerfsen.nvke"
	@echo "  make lint          ansible-lint (production profile) and playbook syntax"
	@echo "  make docs          regenerate docs/variables.md from the argument specs"
	@echo "  make image         build the NVKE node image on the first kvm_hosts host"
	@echo "  make kvm           NVKE on KVM: image, VMs, then the management cluster"
	@echo "  make kvm-destroy   destroy the KVM VMs (asks for confirmation)"
	@echo "  make build         build the collection tarball for Galaxy"

$(BIN)/ansible-playbook:
	python3 -m venv $(VENV)
	$(BIN)/pip install -q -r requirements.txt

dev: $(BIN)/ansible-playbook
	$(BIN)/ansible-galaxy collection install -r requirements.yml -p .collections
	mkdir -p .collections/ansible_collections/omerfsen
	ln -sfn ../../.. .collections/ansible_collections/omerfsen/nvke

lint: dev
	$(BIN)/ansible-lint --profile production
	$(BIN)/ansible-playbook --syntax-check playbooks/*.yml

docs: dev
	$(BIN)/python tools/gen-variables-doc.py

image: dev
	$(BIN)/ansible-playbook playbooks/image.yml

kvm: dev
	$(BIN)/ansible-playbook playbooks/kvm.yml

kvm-destroy: dev
	@read -r -p "Destroy every NVKE VM in inventory/kvm? Type yes: " answer; \
	  $(BIN)/ansible-playbook playbooks/kvm_destroy.yml -e nvke_kvm_destroy_confirm=$$answer

build: dev
	$(BIN)/ansible-galaxy collection build --force

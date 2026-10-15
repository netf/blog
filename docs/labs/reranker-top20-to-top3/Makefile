VENV ?= .venv
PY := $(VENV)/bin/python

.PHONY: reproduce venv preflight analyze clean

# One command: create the venv, check the machine, run everything, regenerate results/summary.md.
# Several hours on a 4-vCPU box; most of it is encoding FiQA with bge-large.
reproduce: venv
	PYTHON=$(abspath $(PY)) PATH=$(abspath $(VENV))/bin:$$PATH ./scripts/run_all.sh

venv: $(PY)
$(PY): requirements.txt
	python3 -m venv $(VENV)
	$(PY) -m pip install -q --upgrade pip
	$(PY) -m pip install -q -r requirements.txt
	touch $(PY)

preflight: venv
	PYTHON=$(abspath $(PY)) ./scripts/00-preflight.sh

analyze: venv
	$(PY) scripts/analyze.py

# Removes the vector cache only; raw results under results/ are kept.
clean:
	rm -rf .cache/emb

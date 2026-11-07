# Project Overview
Student-facing companion repo for the Intermediate DevOps course (Harness CI/CD, IaC, credentials, Docker, Kubernetes). Holds everything learners use: labs, the flight-status app, reference solutions, catch-up scripts, and released slide PDFs. Authoring happens in the primary repo [intermediate-devops](https://github.com/kpassoubady/intermediate-devops); do not link to it from student-facing files.

## Directory Layout
- `labs/`: nine lab guides (`01-…` to `09-…`) plus `img/`.
- `app/`: starter flight-status FastAPI app with tests.
- `solutions/`: reference files per lab (`solutions/labNN/...`).
- `scripts/`: `catch-up.sh` and `labNN-catch-up.sh`; bring a fresh machine to the start of a lab.
- `tests/`: `run-lab.py` and `lib.sh`; run the labs end to end (instructor QA).
- `slides/`: released PDFs (`day1.pdf` to `day3.pdf`), exported from the primary repo.
- `llm-context/`: Stores context for LLM agents.

## Setup
Learners get a provided Linux VM; there is no separate setup repo and no pre-class installation. Tools are installed inside Lab 01 and later labs. Labs clone this repo to `~/intermediate-devops-companion`.

## Verification Steps
- `markdownlint labs/*.md README.md`
- `tests/run-lab.py labs/01-lab-environment.md` (needs a lab VM)

## Content Guidelines
- Keep labs runnable and student-facing; one lab file per lab (no start/solution split).
- Slides are never edited here; replace the PDFs when a new release is exported from the primary repo.

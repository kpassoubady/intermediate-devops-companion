## Course Description

A hands-on introduction to core DevOps workflows as United teams practice them: building CI/CD pipelines in Harness, provisioning infrastructure as code, managing credentials, and deploying containerized applications to Kubernetes. Each participant works on a personal Linux lab machine running Harness Open Source, Docker, and a local Kubernetes cluster, and every lab explains what each step does and why.

## What This Course Covers

This Intermediate DevOps course suits individuals with basic IT or development experience and a basic understanding of DevOps who want to build practical skills in key DevOps areas. Participants learn to design and implement foundational CI/CD pipelines in Harness for automating software delivery, apply Infrastructure as Code (IaC) tools for repeatable infrastructure provisioning, and securely manage credentials within their workflows. The course also covers essential containerization concepts using Docker and guides participants through deploying and managing applications on a Kubernetes cluster from a Harness pipeline. Examples follow the patterns United uses on AWS, including Amazon EKS and Amazon ECS/Fargate, using local equivalents on each participant's lab machine.

## Audience

This course is ideal for:

* Developers interested in learning DevOps practices
* Business Analysts
* Quality Engineers
* Engineers moving into cloud and DevOps roles (for example, from mainframe or operations work)

## Prerequisites

To succeed in this course, participants need:

* Basic IT and software development experience
* Some experience with scripting or programming
* Exposure to basic DevOps principles
* Comfort working at a Linux command line

Recommended preparation: the Pluralsight DevOps Foundations Skill IQ, followed by about 30 minutes of the e-learning it recommends.

## Objectives

By the end of the course, participants will be able to:

* Design and implement a foundational CI/CD pipeline in Harness that builds, tests, and deploys an application
* Provision and manage basic infrastructure components in a repeatable and version-controlled manner
* Implement secure practices for handling and managing sensitive information within CI/CD pipelines
* Use Docker to package applications into containers and manage their lifecycle
* Deploy and manage containerized applications on a Kubernetes cluster from a pipeline, including updates and rollbacks
* Explain what each pipeline and infrastructure step does, and troubleshoot common failures

## Length

3 days

## Lab Environment

Each participant receives a personal, browser-accessible Linux lab machine. Participants install and configure the tools during the labs: Harness Open Source (Harness's free, self-hosted code and pipeline platform), Docker, a local Kubernetes cluster (k3d), and Terraform. No AWS or Harness accounts are required. The local Kubernetes cluster stands in for Amazon EKS, and local containers stand in for Amazon ECS/Fargate.

Lab machine specification: Ubuntu 24.04 with desktop, 8 vCPUs, 16 GB RAM, 80 GB disk, outbound internet access.

## Outline

### CI/CD and Basic Pipelines

* CI/CD concepts and benefits
* CI/CD pipeline creation in Harness: pipelines, stages, steps, and triggers
* Understanding build, test, and deploy stages
* Introduction to automated testing strategies
* Reading pipeline YAML and logs to understand and fix failures
* How Harness Open Source maps to the Harness platform used at United

### Infrastructure as Code (IaC)

* Basic IaC principles and benefits
* Introduction to a single IaC tool (Terraform), and how it compares with AWS CloudFormation and CDK
* Writing basic infrastructure code for simple deployments on the local Kubernetes cluster
* Version control for infrastructure code, and running it from a pipeline

### Basic Credential Management

* Understanding credential management challenges
* Introduction to basic secrets management
* Using secrets in Harness pipelines and Kubernetes without exposing them in code or logs
* Where an enterprise secrets manager fits in the delivery workflow

### Containerization Concepts

* Introduction to containerization (Docker)
* Building and managing Docker images, and pushing them to a registry
* Running and managing Docker containers
* How the same container runs on Amazon ECS/Fargate: task definitions compared with a local Docker Compose file

### Kubernetes Orchestration

* Basic Kubernetes concepts (Pods, Deployments, Services)
* Deploying containerized applications to Kubernetes from a Harness pipeline
* Rolling updates, rollbacks, and checking deployment health
* How the local cluster (k3d) compares with Amazon EKS
* End-to-end lab: one pipeline that tests, builds, and deploys a sample application

## What This Course Does Not Cover

This course focuses on foundational, hands-on DevOps workflows. It does not cover:

* Administration of United's Harness platform (delegates, connectors, templates, access control, and policies), which United's internal teams own
* Work in AWS accounts. Amazon EKS and ECS/Fargate appear through local equivalents on the lab machine.
* Advanced Kubernetes administration, multi-cluster management, or authoring Helm charts
* Complex Infrastructure as Code modules, cloud provider automation, or production-grade pipelines
* Security compliance, policy-as-code, or advanced secrets management systems

Participants should expect a practical, example-driven course that builds confidence with essential DevOps tools and processes.

## Tenets of Pluralsight Instructor Led Training

* **Learn by doing:** Primarily a hands-on experience, Pluralsight training integrates interactive learning such as scenario-based activities, exercises, and labs to reinforce key concepts. We aim for 70% interactive, hands-on work, so participants apply what they learn, while the other 30% is expert-led lecture from industry professionals that provides key insights and foundational knowledge.
* **Learn from practitioners:** Industry-leading practitioners with real-world experience in their fields teach the course. With a deep understanding of industry challenges and best practices, our instructors provide valuable insights and practical knowledge, so learners gain skills that apply directly to their work environments.
* **Learn best with relevant examples:** We configure classes to an organization's industry and business practices to create a relevant training environment. Participants who engage with examples closely aligned with their real-world experiences learn more effectively and apply the concepts directly to real-world situations, which improves both understanding and practical implementation.

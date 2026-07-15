// Jenkins pipeline for agent007 -> Amazon Bedrock AgentCore.
//
// Design: Jenkins runs on a shared box (cluster9) and does NO docker builds
// locally. It hands the build to AWS CodeBuild (native arm64), then updates the
// AgentCore Runtime and smoke-tests it. This keeps the Jenkins host lightweight.
//
// Flow:  checkout -> CodeBuild (build+push to ECR) -> update runtime -> smoke test
//
// AWS auth: the Jenkins host's EC2 instance role (no stored keys).
// Trigger:  SCM polling every ~5 min (the host has no public IP for webhooks).

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 30, unit: 'MINUTES')
  }

  triggers {
    pollSCM('H/5 * * * *')
  }

  parameters {
    string(name: 'AWS_REGION',         defaultValue: 'us-east-1',                                   description: 'Region of ECR / CodeBuild / AgentCore')
    string(name: 'AWS_ACCOUNT_ID',     defaultValue: '813923511679',                                description: 'AWS account id')
    string(name: 'ECR_REPO',           defaultValue: 'bedrock-agentcore-agent007',                  description: 'ECR repository name')
    string(name: 'CODEBUILD_PROJECT',  defaultValue: 'bedrock-agentcore-agent007-builder',          description: 'CodeBuild project that builds the arm64 image')
    string(name: 'SOURCE_BUCKET',      defaultValue: 'bedrock-agentcore-codebuild-sources-813923511679-us-east-1', description: 'S3 bucket for CodeBuild source uploads')
    string(name: 'AGENT_RUNTIME_NAME', defaultValue: 'agent007',                                    description: 'AgentCore runtime name (create-or-update)')
    string(name: 'EXECUTION_ROLE_ARN', defaultValue: 'arn:aws:iam::813923511679:role/AmazonBedrockAgentCoreSDKRuntime-us-east-1-084228a16d', description: 'Runtime execution role ARN')
    string(name: 'SMOKE_MODEL',        defaultValue: '',                                            description: 'Model for the smoke test (empty = agent default)')
    booleanParam(name: 'RUN_SMOKE_TEST', defaultValue: true,                                        description: 'Invoke the runtime after deploy')
  }

  environment {
    AWS_REGION         = "${params.AWS_REGION}"
    AWS_ACCOUNT_ID     = "${params.AWS_ACCOUNT_ID}"
    ECR_REPO           = "${params.ECR_REPO}"
    CODEBUILD_PROJECT  = "${params.CODEBUILD_PROJECT}"
    SOURCE_BUCKET      = "${params.SOURCE_BUCKET}"
    AGENT_RUNTIME_NAME = "${params.AGENT_RUNTIME_NAME}"
    EXECUTION_ROLE_ARN = "${params.EXECUTION_ROLE_ARN}"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.IMAGE_TAG = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          echo "Deploying commit ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Preflight') {
      steps {
        sh '''
          set -e
          aws --version
          git --version
          chmod +x deploy/*.sh
          echo "Caller identity:"
          aws sts get-caller-identity --query Arn --output text
        '''
      }
    }

    stage('Build image (CodeBuild)') {
      steps {
        sh 'IMAGE_TAG="${IMAGE_TAG}" ./deploy/codebuild_build.sh'
      }
    }

    // Manual gate: the image is built & pushed, but nothing has touched the LIVE
    // runtime yet. A human must approve before we roll production. Waiting here
    // does NOT hold a build executor. Auto-aborts after 60 min if unattended.
    stage('Approve prod deploy') {
      options { timeout(time: 60, unit: 'MINUTES') }
      input {
        message "Image ${env.IMAGE_TAG} is built. Deploy it to the LIVE 'agent007' runtime?"
        ok "Deploy to prod"
      }
      steps {
        echo "Approved — deploying ${env.IMAGE_TAG} to the live runtime."
      }
    }

    stage('Deploy to AgentCore') {
      steps {
        sh './deploy/update_runtime.sh'
      }
    }

    stage('Smoke test') {
      when { expression { params.RUN_SMOKE_TEST } }
      steps {
        sh 'SMOKE_MODEL="${SMOKE_MODEL}" ./deploy/smoke_test.sh'
      }
    }
  }

  post {
    success {
      script {
        if (fileExists('deploy_output.env')) {
          archiveArtifacts artifacts: 'deploy_output.env,build_output.env', fingerprint: true, allowEmptyArchive: true
          echo "Deploy outputs:\n" + readFile('deploy_output.env')
        }
      }
    }
    failure { echo '❌ Pipeline failed — see stage logs (CodeBuild deep-link is printed on build failure).' }
    always  { cleanWs(notFailBuild: true) }
  }
}

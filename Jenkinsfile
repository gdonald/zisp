// Runs in the home lab's Jenkins: ./test.sh in one pod running the zisp CI
// image built from docker/. When it passes, Jenkins reports the
// continuous-integration/jenkins/branch status, which starts
// .github/workflows/ci.yml on the same commit.

def buildPod = '''
  apiVersion: v1
  kind: Pod
  spec:
    containers:
      - name: ci
        image: harbor.home.gregdonald.com/zisp/ci:latest
        imagePullPolicy: Always
        command: ["sleep"]
        args: ["infinity"]
        resources:
          requests:
            cpu: "4"
            memory: 8Gi
          limits:
            cpu: "8"
            memory: 8Gi
'''

pipeline {
  agent {
    kubernetes {
      defaultContainer 'ci'
      yaml buildPod
    }
  }

  options {
    disableConcurrentBuilds(abortPrevious: true)
    timeout(time: 30, unit: 'MINUTES')
  }

  stages {
    stage('test') {
      steps {
        sh './test.sh'
      }
      post {
        always {
          archiveArtifacts artifacts: 'coverage/test/coverage.json', allowEmptyArchive: true
        }
      }
    }
  }
}

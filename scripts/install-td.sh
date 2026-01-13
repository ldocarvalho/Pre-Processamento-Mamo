#!/usr/bin/env bash
# install-td.sh - Technical Debt automation package
# Requires: bash 4+, gh CLI authenticated

set -euo pipefail

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER=$(gh api user --jq '.id')
PROJECT_TITLE="Technical Debt Kanban"
ISSUE_TEMPLATE_DIR=".github/ISSUE_TEMPLATE"
WORKFLOW_DIR=".github/workflows"

# TD Statuses and colors
declare -A STATUS_COLORS=(
  ["TD identified"]="YELLOW"
  ["TD documented"]="BLUE"
  ["TD communicated"]="ORANGE"
  ["TD prioritized"]="RED"
  ["TD in repayment"]="GREEN"
  ["TD in monitoring"]="PURPLE"
  ["TD archived"]="GRAY"
  ["TD ignored"]="PINK"
)

echo "▶ Creating Issue template..."
mkdir -p "$ISSUE_TEMPLATE_DIR"
cat > "$ISSUE_TEMPLATE_DIR/td-traceability.md" <<EOF
---
name: TD Traceability
about: Track technical debt
title: "[TD]"
labels: TD identified
---

## Context
_Describe the issue or problem identified_

## Impact
_Describe the impact for tech or business_

## Evidences
_Links to videos, code, logs_

## Additional details
_Original pull request, app version, analytics_
EOF
echo "✔ Issue template created."

declare -A STATUS_COLORS=(
  ["TD identified"]="YELLOW"
  ["TD documented"]="BLUE"
  ["TD communicated"]="ORANGE"
  ["TD prioritized"]="RED"
  ["TD in repayment"]="GREEN"
  ["TD in monitoring"]="PURPLE"
  ["TD archived"]="GRAY"
  ["TD ignored"]="PINK"
)

echo "▶ Creating labels..."
for label in "${!STATUS_COLORS[@]}"; do
  color="${STATUS_COLORS[$label]}"
  if ! gh label list --limit 100 | grep -iq "^$label"; then
    gh label create "$label" --color "$color" || echo "⚠ Could not create $label"
  else
    echo "✔ Label exists: $label"
  fi
done
echo "✔ Labels created."

echo "▶ Fetching or creating Project..."
PROJECT_ID=$(gh api graphql -f query='
query($owner:ID!,$title:String!){
  repository(owner:"'$REPO'",$title:$title) { projectsV2(first:10) { nodes { id title } } }
}' --jq ".data.repository.projectsV2.nodes[] | select(.title==\"$PROJECT_TITLE\") | .id" || true)

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gh api graphql -f query='mutation($ownerId:ID!,$title:String!){
    createProjectV2(input:{ownerId:$ownerId,title:$title}){ projectV2 { id } }
  }' -f ownerId="$OWNER" -f title="$PROJECT_TITLE" --jq '.data.createProjectV2.projectV2.id')
  echo "✔ Project created with ID: $PROJECT_ID"
else
  echo "✔ Using existing Project ID: $PROJECT_ID"
fi

echo "▶ Creating/fetching Status field..."
FIELD_NAME="Status"
FIELD_ID=$(gh api graphql -f query='
query($projectId:ID!,$fieldName:String!){
  node(id:$projectId) { ... on ProjectV2 { fields(first:20){ nodes { id name } } } }
}' -f projectId="$PROJECT_ID" -f fieldName="$FIELD_NAME" --jq ".node.fields.nodes[] | select(.name==\"$FIELD_NAME\") | .id" || true)

if [[ -z "$FIELD_ID" ]]; then
  FIELD_ID=$(gh api graphql -f query='
mutation($projectId:ID!,$name:String!){
  createProjectV2Field(input:{projectId:$projectId,name:$name,dataType:SINGLE_SELECT}){ projectV2Field { ... on ProjectV2SingleSelectField { id } } }
}' -f projectId="$PROJECT_ID" -f name="$FIELD_NAME" --jq '.data.createProjectV2Field.id')
  echo "✔ Status field created: $FIELD_ID"
else
  echo "✔ Using existing Status field: $FIELD_ID"
fi

echo "▶ Adding options to Status field..."
for status in "${!STATUS_COLORS[@]}"; do
  color="${STATUS_COLORS[$status]}"
  EXISTS=$(gh api graphql -f query='
query($fieldId:ID!,$optionName:String!){
  node(id:$fieldId){ ... on ProjectV2SingleSelectField { options(first:20){ nodes{ name } } } }
}' -f fieldId="$FIELD_ID" -f optionName="$status" --jq ".node.options.nodes[] | select(.name==\"$status\") | .name" || true)

  if [[ -z "$EXISTS" ]]; then
    gh api graphql -f query='
mutation($projectId:ID!,$fieldId:ID!,$optionName:String!,$color:ProjectV2SingleSelectFieldOptionColor!){
  addProjectV2SingleSelectOption(input:{projectId:$projectId,fieldId:$fieldId,name:$optionName,description:$optionName,color:$color}){ singleSelectOption { id } }
}' -f projectId="$PROJECT_ID" -f fieldId="$FIELD_ID" -f optionName="$status" -f color="$color"
    echo "✔ Option added: $status"
  else
    echo "✔ Option exists: $status"
  fi
done

echo "▶ Creating fake issues to initialize Kanban columns..."
for status in "${!STATUS_COLORS[@]}"; do
  gh issue create -t "TD placeholder - $status" -b "Placeholder for column $status" -l "$status" --assignee @me || true
done
echo "✔ Fake issues created for Kanban columns."

echo "▶ Creating workflow..."
mkdir -p "$WORKFLOW_DIR"
cat > "$WORKFLOW_DIR/td-status-sync.yml" <<'EOF'
name: TD Status Sync
on:
  issues:
    types: [opened, labeled, unlabeled]
  workflow_dispatch:
jobs:
  sync-status:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/github-script@v6
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const projectTitle = "Technical Debt Kanban";
            const statusFieldName = "Status";
            const issueLabels = context.payload.issue.labels.map(l=>l.name);
            const projectIdQuery = `query {
              repository(owner:"${context.repo.owner}", name:"${context.repo.repo}") {
                projectsV2(first:10) { nodes { id title fields(first:20){ nodes { id name } } } }
              }
            }`;
            const projectResp = await github.graphql(projectIdQuery);
            const project = projectResp.repository.projectsV2.nodes.find(p=>p.title===projectTitle);
            if(!project) return;
            const statusField = project.fields.nodes.find(f=>f.name===statusFieldName);
            if(!statusField) return;
            const currentLabel = issueLabels.find(l=>l.startsWith("TD "));
            if(currentLabel){
              await github.graphql(`mutation($projectId:ID!,$itemId:ID!,$fieldId:ID!,$optionName:String!){
                updateProjectV2ItemField(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:$optionName}){ projectV2Item{ id } }
              }`, { projectId: project.id, itemId: context.payload.issue.node_id, fieldId: statusField.id, optionName: currentLabel });
            }
EOF
echo "✔ Workflow created."

echo "✅ Technical Debt package installed successfully!"
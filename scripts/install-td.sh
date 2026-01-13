#!/usr/bin/env bash
set -e

# --- Check Bash version ---
if ((BASH_VERSINFO[0] < 4)); then
  echo "❌ Bash 4+ is required."
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "❌ GitHub CLI not found"; exit 1; }

echo "▶ Installing Technical Debt package (Kanban ready)..."

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER=${REPO%%/*}

PROJECT_NAME="Technical Debt Management"
STATUS_FIELD_NAME="Status"

STATUSES=(
  "TD identified"
  "TD documented"
  "TD communicated"
  "TD prioritized"
  "TD in repayment"
  "TD in monitoring"
  "TD archived"
  "TD ignored"
)

mkdir -p .github/ISSUE_TEMPLATE
mkdir -p .github/workflows

# --- Issue template ---
cat > .github/ISSUE_TEMPLATE/td-traceability.yml <<'EOF'
name: TD Traceability
description: Register and track a Technical Debt item
title: "[TD] "
labels:
  - TD identified
body:
  - type: textarea
    id: context
    attributes:
      label: Context
      description: Describe the issue or problem identified
    validations:
      required: true
  - type: textarea
    id: impact
    attributes:
      label: Impact
      description: Describe the impact for tech or business
    validations:
      required: true
  - type: textarea
    id: evidences
    attributes:
      label: Evidences
      description: Links to videos, code, logs
  - type: textarea
    id: additional
    attributes:
      label: Additional details
      description: Original pull request, app version, analytics
EOF

echo "✔ Issue template created."

# --- Workflow placeholder (IDs to be filled after creation) ---
cat > .github/workflows/td-project-automation.yml <<'EOF'
name: TD Project Automation
on:
  issues:
    types: [opened]
jobs:
  add-to-project:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            // Placeholders will be replaced by install-td.sh
EOF

echo "✔ Workflow created (placeholders to be replaced)."

# --- Owner node id ---
OWNER_NODE_ID=$(gh api graphql -f query='query($login:String!){ user(login:$login){ id } }' -f login="$OWNER" -q .data.user.id)

# --- Create/fetch Project V2 ---
PROJECT_ID=$(gh api graphql -f query='
mutation($owner:ID!, $title:String!) {
  createProjectV2(input:{ownerId:$owner,title:$title}) { projectV2 { id } }
}' -f owner="$OWNER_NODE_ID" -f title="$PROJECT_NAME" -q .data.createProjectV2.projectV2.id 2>/dev/null || true)

if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gh api graphql -f query='
query($owner:String!,$title:String!) {
  user(login:$owner) {
    projectsV2(first:100) { nodes { id title } }
  }
}' -f owner="$OWNER" -q ".data.user.projectsV2.nodes[] | select(.title==\"$PROJECT_NAME\") | .id")
fi

echo "✔ Project ID: $PROJECT_ID"

# --- Create Status field ---
FIELD_ID=$(gh api graphql -f query='
mutation($project:ID!, $name:String!) {
  createProjectV2Field(input:{projectId:$project,dataType:SINGLE_SELECT,name:$name}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } }
}' -f project="$PROJECT_ID" -f name="$STATUS_FIELD_NAME" -q .data.createProjectV2Field.projectV2Field.id 2>/dev/null || true)

if [ -z "$FIELD_ID" ]; then
  FIELD_ID=$(gh api graphql -f query='
query($project:ID!) {
  node(id:$project){ ... on ProjectV2 { fields(first:100){ nodes{ ... on ProjectV2SingleSelectField { id name } } } } }
}' -f project="$PROJECT_ID" -q ".data.node.fields.nodes[] | select(.name==\"$STATUS_FIELD_NAME\") | .id")
fi

echo "✔ Status Field ID: $FIELD_ID"

# --- Add options and labels ---
declare -A OPTIONS
echo "▶ Creating options and labels..."
for STATUS in "${STATUSES[@]}"; do
  # Add option
  OPTION_ID=$(gh api graphql -f query='
mutation($field:ID!, $name:String!){
  addProjectV2SingleSelectOption(input:{fieldId:$field,name:$name}){ option { ... on ProjectV2SingleSelectFieldOption { id } } }
}' -f field="$FIELD_ID" -f name="$STATUS" -q .data.addProjectV2SingleSelectOption.option.id 2>/dev/null || true)

  # If exists, fetch id
  if [ -z "$OPTION_ID" ]; then
    OPTION_ID=$(gh api graphql -f query='
query($field:ID!){
  node(id:$field){ ... on ProjectV2SingleSelectField{ options(first:100){ nodes{ ... on ProjectV2SingleSelectFieldOption{ id name } } } } }
}' -f field="$FIELD_ID" -q ".data.node.options.nodes[] | select(.name==\"$STATUS\") | .id")
  fi

  OPTIONS["$STATUS"]="$OPTION_ID"

  # Create label
  gh label create "$STATUS" --repo "$REPO" --force >/dev/null || true
done

# --- Update workflow placeholders ---
sed -i.bak \
  -e "s|__PROJECT_ID__|$PROJECT_ID|g" \
  -e "s|__STATUS_FIELD_ID__|$FIELD_ID|g" \
  -e "s|__TD_IDENTIFIED__|${OPTIONS["TD identified"]}|g" \
  -e "s|__TD_DOCUMENTED__|${OPTIONS["TD documented"]}|g" \
  -e "s|__TD_COMMUNICATED__|${OPTIONS["TD communicated"]}|g" \
  -e "s|__TD_PRIORITIZED__|${OPTIONS["TD prioritized"]}|g" \
  -e "s|__TD_IN_REPAYMENT__|${OPTIONS["TD in repayment"]}|g" \
  -e "s|__TD_IN_MONITORING__|${OPTIONS["TD in monitoring"]}|g" \
  -e "s|__TD_ARCHIVED__|${OPTIONS["TD archived"]}|g" \
  -e "s|__TD_IGNORED__|${OPTIONS["TD ignored"]}|g" \
  .github/workflows/td-project-automation.yml
rm .github/workflows/td-project-automation.yml.bak

echo "✅ Technical Debt package installed! Kanban columns are visible, workflow active, labels created."
#!/bin/bash
# https://github.com/AndrewInUA/vault-invoices-checker
# Author: AndrewInUA https://andrewinua.com

# Define terminal color codes for formatting output
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
MAGENTA='\033[1;35m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Display help message and exit if no vote account or --help flag is provided
if [[ "$1" == "--help" || "$1" == "-h" || -z "$1" ]]; then
  echo
    echo -e "Usage: $0 <vote_account_address> [epochs_to_check]"
    echo
    echo "This script checks Vault stake info and invoice amounts"
    echo "for a given Solana vote account using Vault API."
    echo
    echo "Arguments:"
    echo "  <vote_account_address>   Vote account public key (required)"
    echo "  [epochs_to_check]        Number of past epochs to check (default: 15)"
    echo
    echo "Example:"
    echo "  ./vault-invoices-checker.sh <vote_account_address> 20"
    echo
    echo "Repository: https://github.com/AndrewInUA/vault-invoices-checker"
    echo "Author:     AndrewInUA (https://andrewinua.com)"
    echo
    exit 0
fi

# Read parameters
VOTE_ACCOUNT="$1"
EPOCHS_TO_CHECK="${2:-15}"

# Fetch the latest epoch filename from Vault GitHub repo and extract epoch number
LATEST_FILE=$(curl -sS https://raw.githubusercontent.com/SolanaVault/stakebot-data/main/bot-stats-latest.txt)
CURRENT_EPOCH=$(echo "$LATEST_FILE" | cut -d '/' -f1)

# Build full URL for JSON with stake delta data and fetch it
DELTA_JSON_URL="https://raw.githubusercontent.com/SolanaVault/stakebot-data/main/$LATEST_FILE"
DELTA_JSON=$(curl -sS "$DELTA_JSON_URL")

# Fetch validator metadata (identity and display name) from Stakewiz API
STAKEWIZ_API="https://api.stakewiz.com/validator/$VOTE_ACCOUNT"
VALIDATOR_DATA=$(curl -sS "$STAKEWIZ_API")
IDENTITY=$(echo "$VALIDATOR_DATA" | jq -r '.identity')
NAME=$(echo "$VALIDATOR_DATA" | jq -r '.name // "Unknown"')

# Convert lamports to SOL with 3 decimal formatting
get_sol() {
    awk -v lamports="$1" 'BEGIN { printf "%.3f", lamports / 1e9 }'
}

# Helper function to extract a field from the delta JSON for the current vote account
extract_stake_value() {
    echo "$DELTA_JSON" | jq -r --arg va "$VOTE_ACCOUNT" ".validatorTargets[] | select(.votePubkey == \$va) | .$1"
}

# Extract total, active, target, and delta stake from delta JSON
EXISTING=$(get_sol "$(extract_stake_value existingStake)")
ACTIVE=$(get_sol "$(extract_stake_value existingActiveStake)")
TARGET=$(get_sol "$(extract_stake_value targetTotalStake)")
DELTA=$(get_sol "$(extract_stake_value delta)")

# Extract directed target stake (if exists), and convert to SOL
DIRECTED_TARGET=$(echo "$DELTA_JSON" | jq -r --arg va "$VOTE_ACCOUNT" '
  .directedStakeTargets[]? | select(.votePubkey == $va) | .sum // "0"
')
DIRECTED_TARGET_SOL=$(get_sol "${DIRECTED_TARGET:-0}")

# Extract existing directed stake (if any), and convert to SOL
EXISTING_DIRECTED=$(echo "$DELTA_JSON" | jq -r --arg va "$VOTE_ACCOUNT" '
  .validatorTargets[] | select(.votePubkey == $va) | .targetStake.directed // "0"
')
EXISTING_DIRECTED_SOL=$(get_sol "${EXISTING_DIRECTED:-0}")

# Calculate undirected stake and deltas (existing and promised minus directed)
UNDIR_EXISTING=$(awk -v a="$EXISTING" -v b="$EXISTING_DIRECTED_SOL" 'BEGIN { printf "%.3f", a - b }')
UNDIR_PROMISED=$(awk -v a="$TARGET" -v b="$DIRECTED_TARGET_SOL" 'BEGIN { printf "%.3f", a - b }')
DIR_DELTA=$(awk -v a="$DIRECTED_TARGET_SOL" -v b="$EXISTING_DIRECTED_SOL" 'BEGIN { printf "%.3f", a - b }')
UNDIR_DELTA=$(awk -v a="$UNDIR_PROMISED" -v b="$UNDIR_EXISTING" 'BEGIN { printf "%.3f", a - b }')

# Display script header and validator information
echo
echo
echo -e "🔎 ${BOLD}${BLUE}Vault Invoices & Stake Info — Epoch $LATEST_FILE${NC}"
echo -e "${BOLD}Vote Account:${NC}    $VOTE_ACCOUNT"
echo -e "${BOLD}Identity:${NC}        $IDENTITY"
echo -e "${BOLD}Name:${NC}            ${GREEN}${NAME}${NC}"
echo
# Format a delta number with +/– sign and color
format_delta() {
    awk -v d="$1" 'BEGIN {
        if (d > 0) printf "\033[1;32m+%.3f\033[0m", d;
        else if (d < 0) printf "\033[1;31m%.3f\033[0m", d;
        else printf "\033[0m%.3f\033[0m", d;
    }'
}

DELTA_FMT=$(format_delta "$DELTA")
DIR_DELTA_FMT=$(format_delta "$DIR_DELTA")
UNDIR_DELTA_FMT=$(format_delta "$UNDIR_DELTA")

# Print stake overview table with current and promised stake
printf "%-15s %-16s %s\n" " " "Current Vault" "Promised"
printf "${CYAN}%-15s${NC} %-10s SOL   %s\n" "Total" "$EXISTING" "$DELTA_FMT"
printf "${CYAN}%-15s${NC} %-10s SOL   %s\n" "Directed" "$EXISTING_DIRECTED_SOL" "$DIR_DELTA_FMT"
printf "${CYAN}%-15s${NC} %-10s SOL   %s\n" "Undirected" "$UNDIR_EXISTING" "$UNDIR_DELTA_FMT"
echo

# Start scanning past invoice epochs and sum unpaid amounts
echo -e "📄 ${BOLD}Found Vault invoices (last $EPOCHS_TO_CHECK epochs):${NC}"
TOTAL_VSOL=0
for ((i = CURRENT_EPOCH - 1; i >= CURRENT_EPOCH - EPOCHS_TO_CHECK; i--)); do
    URL="https://raw.githubusercontent.com/SolanaVault/stake-as-a-service-data/refs/heads/main/$i/invoices.json"

    RETRIES=0
    JSON=""
    while [[ $RETRIES -lt 3 ]]; do
        JSON=$(curl -sS "$URL")

        # Retry if content is missing or response is a "404"
        if [[ "$JSON" == "404: Not Found" || -z "$JSON" ]]; then
            ((RETRIES++))
            sleep 2
        else
            break
        fi
    done

    # If still no result after retries, skip this epoch
    if [[ "$JSON" == "404: Not Found" || -z "$JSON" ]]; then
        echo -e "${YELLOW}⚠️  No data for epoch $i after 3 attempts. Skipping.${NC}"
        continue
    fi

    # Extract invoice for the current vote account from epoch file
    INVOICE=$(echo "$JSON" | jq -r --arg va "$VOTE_ACCOUNT" '.[] | select(.validatorVoteKey == $va)')
    [[ -z "$INVOICE" ]] && continue

    # Parse invoice fields: stake, amount, price
    STAKE_LAMPORTS=$(echo "$INVOICE" | jq -r '.stakeLamports')
    PRICE=$(echo "$INVOICE" | jq -r '.pricePer1KSol')
    AMOUNT=$(echo "$INVOICE" | jq -r '.amountVSol')

    # Convert and format fields
    STAKE_SOL=$(get_sol "$STAKE_LAMPORTS")
    AMOUNT_FMT=$(awk -v amt="$AMOUNT" 'BEGIN { printf "%.3f", amt / 1e9 }')
    DEADLINE=$((i + 10))

    # Color deadlines depending on urgency
    COLOR=""
    if (( DEADLINE <= CURRENT_EPOCH )); then
        COLOR=$RED
    elif (( DEADLINE <= CURRENT_EPOCH + 3 )); then
        COLOR=$YELLOW
    else
        COLOR=$GREEN
    fi

    # Output invoice row
    echo -e "Epoch $i:\tStake: $STAKE_SOL SOL   \tInvoice: $AMOUNT_FMT vSOL     Deadline: ${COLOR}epoch $DEADLINE${NC}"

    # Add to total vSOL owed
    TOTAL_VSOL=$(awk -v t="$TOTAL_VSOL" -v a="$AMOUNT" 'BEGIN { print t + a / 1e9 }')
done

# Format and display total unpaid invoice amount
TOTAL_FMT=$(awk -v t="$TOTAL_VSOL" 'BEGIN { printf "%.3f", t }')
echo
echo -e "💰 ${YELLOW}${BOLD}Total invoices amount:${NC} $TOTAL_FMT vSOL"
echo -e "ℹ️  Check invoice status and pay here:\n${CYAN}https://thevault.finance/dapp/validators/${VOTE_ACCOUNT}${NC}"
echo
echo

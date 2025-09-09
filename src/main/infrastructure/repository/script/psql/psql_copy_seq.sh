#!/bin/sh

# Default script behavior.
set +e

# Default parameters.
DEBUG=true
ENV_FILE="/local/application.env"
SEQ_FILE="/tmp/copy-sequences.sql"
INC_VAL=1000
COPY=false
APPLY=false

# Update environment variables
if [ -f "$ENV_FILE" ]; then
  . "$ENV_FILE"
fi

# For each argument.
while :; do
  case "$1" in
    --debug) 
        DEBUG=true 
    ;;
    --copy)
        COPY=true 
    ;;
    --apply) 
        APPLY=true
    ;;
    *) 
    break
;;
  esac
  shift
done

if [ "$COPY" = "true" ] && [ "$APPLY" = "true" ]; then
  echo "For safety use first copy and then apply"
  exit 1
fi

if [ "$COPY" = "true" ];  then

    echo "GET SEQUENCE AND INCREASE BY: ${INC_VAL}"
    PGPASSWORD=${POSTGRES_ADMIN_PASSWORD:=postgres} psql -h "${MASTER_ENDPOINT}" -p "${MASTER_PORT}" -U ${POSTGRES_ADMIN_USER} -d ${POSTGRES_DEFAULT_DATABASE} -At -c "
    SELECT format(
        'SELECT setval(%L, %s, true);',
        format('%I.%I', schemaname, sequencename),
        COALESCE(last_value, start_value) + increment_by + cache_size + ${INC_VAL}
    )
    FROM pg_sequences
    ORDER BY 1
    " > ${SEQ_FILE}

    echo "SEQUENCE TO APPLY..."
    cat ${SEQ_FILE}
fi

if [ "$APPLY" = "true" ];  then
    echo "APPLYING SEQUENCES..."
    PGPASSWORD="${POSTGRES_ADMIN_PASSWORD:=postgres}" psql -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DEFAULT_DATABASE" -f ${SEQ_FILE}
fi


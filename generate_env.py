#!/usr/bin/env python3
import os
import uuid
import secrets
import string

def generate_password(length=16):
    chars = string.ascii_letters + string.digits + "!%^*"
    return ''.join(secrets.choice(chars) for _ in range(length))

# Generate unique keys
master_key = f"litellm-{uuid.uuid4()}"
salt_key = f"litellm-{uuid.uuid4()}"
admin_password = generate_password()
session_secret = generate_password(32)

# Create .env file (do not overwrite if it already exists)
if os.path.exists('.env'):
    print('Skipped: .env already exists.')
else:
    with open('.env', 'w') as f:
        f.write(f'LITELLM_MASTER_KEY={master_key}\n')
        f.write(f'LITELLM_SALT_KEY={salt_key}\n')
        f.write('UI_USERNAME=ImNotAdmin\n')
        f.write(f'UI_PASSWORD={admin_password}\n')

    print(f'Master Key: {master_key}')
    print(f'Admin Password: {admin_password}\n')

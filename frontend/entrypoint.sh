#!/bin/sh

# 1. Start the file
echo "window.env = {" > ./public/env.js

# 2. Append Variables
echo "  NEXT_PUBLIC_API_URL: \"$NEXT_PUBLIC_API_URL\"," >> ./public/env.js

# 3. Close the object
echo "};" >> ./public/env.js

# Start the App
echo "Starting Next.js..."
exec npm start
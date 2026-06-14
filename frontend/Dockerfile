# frontend/Dockerfile
FROM node:21-alpine

WORKDIR /app

# Install dependencies
COPY package.json package-lock.json ./
RUN npm install

# Copy code
COPY . .

# Build 
RUN npm run build

# Copy Entrypoint Script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3000

# Use the entrypoint script to generate env.js at runtime
ENTRYPOINT ["/entrypoint.sh"]
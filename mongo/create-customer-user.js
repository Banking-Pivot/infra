// Runs once, when the customer-mongo volume is empty. customer-service logs in as this user,
// which can only read and write customers_db; its password reaches the service through Vault.
db.getSiblingDB('customers_db').createUser({
    user: process.env.CUSTOMER_DB_USERNAME,
    pwd: process.env.CUSTOMER_DB_PASSWORD,
    roles: [{ role: 'readWrite', db: 'customers_db' }]
});

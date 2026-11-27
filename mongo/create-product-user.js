// Runs once, when the product-mongo volume is empty. product-service logs in as this user,
// which can only read and write products_db; its password reaches the service through Vault.
db.getSiblingDB('products_db').createUser({
    user: process.env.PRODUCT_DB_USERNAME,
    pwd: process.env.PRODUCT_DB_PASSWORD,
    roles: [{ role: 'readWrite', db: 'products_db' }]
});

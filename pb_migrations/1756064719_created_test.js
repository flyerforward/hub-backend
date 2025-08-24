/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "fkxhq6ojohvosxg",
    "created": "2025-08-24 19:45:19.693Z",
    "updated": "2025-08-24 19:45:19.693Z",
    "name": "test",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "cxsqiqut",
        "name": "test",
        "type": "text",
        "required": false,
        "presentable": false,
        "unique": false,
        "options": {
          "min": null,
          "max": null,
          "pattern": ""
        }
      },
      {
        "system": false,
        "id": "uggg6ayg",
        "name": "test1",
        "type": "number",
        "required": false,
        "presentable": false,
        "unique": false,
        "options": {
          "min": null,
          "max": null,
          "noDecimal": false
        }
      }
    ],
    "indexes": [],
    "listRule": null,
    "viewRule": null,
    "createRule": null,
    "updateRule": null,
    "deleteRule": null,
    "options": {}
  });

  return Dao(db).saveCollection(collection);
}, (db) => {
  const dao = new Dao(db);
  const collection = dao.findCollectionByNameOrId("fkxhq6ojohvosxg");

  return dao.deleteCollection(collection);
})

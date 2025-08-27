/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "rhll7eto3ltrejh",
    "created": "2025-08-27 16:54:35.313Z",
    "updated": "2025-08-27 16:54:35.313Z",
    "name": "pingertest",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "qdbpooyi",
        "name": "field",
        "type": "text",
        "required": false,
        "presentable": false,
        "unique": false,
        "options": {
          "min": null,
          "max": null,
          "pattern": ""
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
  const collection = dao.findCollectionByNameOrId("rhll7eto3ltrejh");

  return dao.deleteCollection(collection);
})

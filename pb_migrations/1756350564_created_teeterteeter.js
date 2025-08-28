/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "mbu7m3ukbqesh4f",
    "created": "2025-08-28 03:09:24.449Z",
    "updated": "2025-08-28 03:09:24.449Z",
    "name": "teeterteeter",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "wukji5n8",
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
  const collection = dao.findCollectionByNameOrId("mbu7m3ukbqesh4f");

  return dao.deleteCollection(collection);
})

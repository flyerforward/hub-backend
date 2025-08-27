/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const collection = new Collection({
    "id": "sqxwl8uz242nsh8",
    "created": "2025-08-26 23:04:32.012Z",
    "updated": "2025-08-26 23:04:32.012Z",
    "name": "ter",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "cciee2nq",
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
  const collection = dao.findCollectionByNameOrId("sqxwl8uz242nsh8");

  return dao.deleteCollection(collection);
})

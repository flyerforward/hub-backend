/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const dao = new Dao(db);
  const collection = dao.findCollectionByNameOrId("oreyh33gp3ado6o");

  return dao.deleteCollection(collection);
}, (db) => {
  const collection = new Collection({
    "id": "oreyh33gp3ado6o",
    "created": "2025-08-27 17:38:57.079Z",
    "updated": "2025-08-27 17:38:57.079Z",
    "name": "fedsafdsafs",
    "type": "base",
    "system": false,
    "schema": [
      {
        "system": false,
        "id": "51yt9lxf",
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
})
